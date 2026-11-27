"""Synthetic OCR provision and the current user's fixed return slot."""

import base64
import hashlib
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from gaocaozuo.errors import AppError
from gaocaozuo.ocr_provider import OcrProvider

pytestmark = pytest.mark.skipif(os.name != "nt", reason="requires Windows return-directory handles")

SOURCE = "com.gaoseries.GaoWenJian"
RESEARCH = "com.academic-achievement.manager"
TARGET = "com.gaoseries.GaoCaoZuo"


class Clock:
    now = datetime(2026, 11, 27, 12, tzinfo=timezone.utc)

    def __call__(self):
        return self.now


class SyntheticOcr:
    def __init__(self, failure=False):
        self.calls = 0
        self.failure = failure

    def recognize_paths(self, paths, languages, *, names, retain_rasters):
        self.calls += 1
        if self.failure:
            raise AppError("synthetic OCR failure", "fixture")
        attachment, = paths
        assert names == ["scan.png"]
        return {"id": "fixture", "status": "completed", "sources": [{
            "sha256": digest(attachment.read_bytes()),
            "pages": [{"page": 1, "status": "completed", "lines": ["sample"], "error": None}],
        }]}

    def source_export(self, identifier, format, index):
        assert (identifier, format, index) == ("fixture", "text", 0)
        return b"synthetic recognized text"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def stamp(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def fixture(tmp_path, *, sender=SOURCE, uppercase=False, failure=False):
    clock = Clock()
    recognizer = SyntheticOcr(failure)
    root = tmp_path / "LocalAppData" / "GaoSeries" / "GaoAction" / "OcrReturns-v1"
    private_store = tmp_path / "provider"
    provider = OcrProvider(private_store, clock=clock, session_factory=lambda: recognizer, return_root=root)
    source = tmp_path / "incoming.gaoaction"
    item = b"synthetic source image"
    (source / "payload").mkdir(parents=True)
    (source / "payload" / "scan.png").write_bytes(item)
    identifier = str(uuid.uuid4())
    expires = stamp(clock.now + timedelta(seconds=120))
    request = {"schemaVersion": 1, "kind": "request", "requestID": identifier.upper() if uppercase else identifier,
               "action": "ocr.files", "sourceBundleID": sender, "targetBundleID": TARGET,
               "createdAt": stamp(clock.now), "expiresAt": expires, "nonce": base64.b64encode(b"n" * 32).decode(),
               "parameters": {"outputs": ["text"]}, "references": [], "items": [{"relativePath": "scan.png",
               "uti": "public.png", "id": "original-1", "byteCount": len(item), "sha256": digest(item)}]}
    # Deliberate whitespace makes this distinguishable from hashes of parsed/reserialized JSON.
    raw = json.dumps(request, indent=3).encode() + b"\r\n  "
    (source / "manifest.json").write_bytes(raw)
    ticket = {"schemaVersion": 1, "requestID": identifier, "action": "ocr.files", "sourceBundleID": sender,
              "targetBundleID": TARGET, "requestManifestSHA256": digest(raw), "expiresAt": expires}
    return provider, clock, recognizer, source, root / identifier, ticket, request


def write_ticket(slot, ticket):
    slot.mkdir(parents=True, exist_ok=True)
    (slot / "request.json").write_bytes(json.dumps(ticket).encode())


@pytest.mark.parametrize("sender", [SOURCE, RESEARCH])
def test_exact_ticket_publishes_once_after_review_and_validates_existing_payload(tmp_path, sender):
    provider, clock, recognizer, source, slot, ticket, request = fixture(tmp_path, sender=sender)
    write_ticket(slot, ticket)
    identifier = request["requestID"]
    assert provider.receive(source)["autoReturn"] == {"targetBundleID": sender, "status": "ready"}
    assert provider.return_result(identifier)["status"] == "pending"
    assert recognizer.calls == 0 and not (slot / "result.gaoaction").exists()
    with pytest.raises(AppError, match="确认识别"):
        provider.approve(identifier, False)

    assert provider.approve(identifier, True)["autoReturn"]["status"] == "published"
    result = slot / "result.gaoaction"
    raw = (result / "manifest.json").read_bytes()
    manifest = json.loads(raw)
    assert manifest["inReplyTo"] == identifier and manifest["targetBundleID"] == sender
    assert manifest["sourceBundleID"] == TARGET and manifest["action"] == "ocr.files"
    assert manifest["provenance"]["requestManifestSHA256"] == ticket["requestManifestSHA256"]
    source = manifest["provenance"]["sources"][0]
    assert source["sourceSHA256"] == request["items"][0]["sha256"] and source["pages"][0]["pageNumber"] == 1
    original = (result / "payload" / "OCR-1.txt").read_bytes()
    assert digest(original) == manifest["items"][0]["sha256"]
    restarted = OcrProvider(provider.root.parent, clock=clock, session_factory=lambda: recognizer, return_root=slot.parent)
    assert restarted.return_result(identifier)["autoReturn"]["status"] == "published"
    assert (result / "manifest.json").read_bytes() == raw and recognizer.calls == 1

    (result / "payload" / "OCR-1.txt").write_bytes(b"untrusted replacement")
    assert restarted.return_result(identifier)["autoReturn"]["status"] == "unavailable"
    assert (result / "manifest.json").read_bytes() == raw
    assert (result / "payload" / "OCR-1.txt").read_bytes() == b"untrusted replacement"
    assert recognizer.calls == 1


@pytest.mark.parametrize(("key", "value"), [
    ("schemaVersion", True), ("requestID", "other"), ("action", "text.replace"),
    ("sourceBundleID", RESEARCH), ("targetBundleID", SOURCE), ("requestManifestSHA256", "0" * 64),
    ("expiresAt", "2026-11-27T12:03:00Z"), ("path", "C:/external"),
])
def test_ticket_fields_are_exact_and_retry_uses_retained_result(tmp_path, key, value):
    provider, _, recognizer, source, slot, ticket, request = fixture(tmp_path)
    write_ticket(slot, {**ticket, key: value})
    identifier = request["requestID"]
    assert provider.receive(source)["autoReturn"]["status"] == "unavailable"
    completed = provider.approve(identifier, True)
    assert completed["status"] == "completed" and completed["autoReturn"]["status"] == "unavailable"
    assert {path.name for path in slot.iterdir()} == {"request.json"}
    manual = provider.export_result(identifier, tmp_path / "manual", True)
    assert manual["status"] == "completed"
    write_ticket(slot, ticket)
    assert provider.return_result(identifier)["autoReturn"]["status"] == "published"
    assert recognizer.calls == 1


def test_ticket_expiry_after_ocr_preserves_manual_output(tmp_path):
    provider, clock, recognizer, source, slot, ticket, request = fixture(tmp_path)
    write_ticket(slot, ticket)
    approve = recognizer.recognize_paths

    def recognize(*args, **kwargs):
        doc = approve(*args, **kwargs)
        clock.now += timedelta(seconds=120)
        return doc

    recognizer.recognize_paths = recognize
    provider.receive(source)
    completed = provider.approve(request["requestID"], True)
    assert completed["status"] == "completed" and completed["autoReturn"]["status"] == "expired"
    assert not (slot / "result.gaoaction").exists()
    assert provider.export_result(request["requestID"], tmp_path / "manual", True)["status"] == "completed"


def test_ticket_expiry_while_staging_refuses_atomic_publish(tmp_path, monkeypatch):
    provider, clock, recognizer, source, slot, ticket, request = fixture(tmp_path)
    write_ticket(slot, ticket)
    write = provider._write_package

    def finish_staging(*args, **kwargs):
        write(*args, **kwargs)
        clock.now += timedelta(seconds=120)

    monkeypatch.setattr(provider, "_write_package", finish_staging)
    provider.receive(source)
    completed = provider.approve(request["requestID"], True)
    assert completed["status"] == "completed" and completed["autoReturn"]["status"] == "expired"
    assert {path.name for path in slot.iterdir()} == {"request.json"} and recognizer.calls == 1


def test_publish_never_overwrites_unrelated_existing_destination(tmp_path):
    provider, _, recognizer, source, slot, ticket, request = fixture(tmp_path)
    write_ticket(slot, ticket)
    destination = slot / "result.gaoaction"
    destination.mkdir()
    existing = destination / "manifest.json"
    existing.write_bytes(b"unrelated result")
    provider.receive(source)
    assert provider.approve(request["requestID"], True)["autoReturn"]["status"] == "unavailable"
    assert provider.return_result(request["requestID"])["autoReturn"]["status"] == "unavailable"
    assert existing.read_bytes() == b"unrelated result" and recognizer.calls == 1


def test_noncanonical_directory_spelling_is_not_an_alias_for_automatic_return(tmp_path):
    provider, _, recognizer, source, slot, ticket, request = fixture(tmp_path)
    uppercase = slot.with_name(slot.name.upper())
    write_ticket(uppercase, ticket)
    assert provider.receive(source)["autoReturn"]["status"] == "unavailable"
    assert provider.approve(request["requestID"], True)["autoReturn"]["status"] == "unavailable"
    assert {path.name for path in uppercase.iterdir()} == {"request.json"} and recognizer.calls == 1


def test_junction_in_fixed_path_never_receives_ocr_data(tmp_path):
    from _winapi import CreateJunction

    provider, _, recognizer, source, slot, ticket, request = fixture(tmp_path)
    outside = tmp_path / "outside"
    write_ticket(outside, ticket)
    slot.parent.mkdir(parents=True)
    try:
        CreateJunction(str(outside), str(slot))
    except PermissionError:
        pytest.skip("The Windows sandbox does not allow creation of test junctions.")
    identifier = request["requestID"]
    assert provider.receive(source)["autoReturn"]["status"] == "unavailable"
    assert provider.approve(identifier, True)["autoReturn"]["status"] == "unavailable"
    assert {path.name for path in outside.iterdir()} == {"request.json"} and recognizer.calls == 1


@pytest.mark.parametrize("changes", [{"sender": "com.example.old"}, {"uppercase": True}, {"failure": True}])
def test_legacy_or_failed_ocr_is_only_manually_exportable(tmp_path, changes):
    provider, _, recognizer, source, slot, ticket, request = fixture(tmp_path, **changes)
    write_ticket(slot, ticket)
    identifier = request["requestID"]
    provider.receive(source)
    completed = provider.approve(identifier, True)
    assert completed["autoReturn"]["status"] == "notEligible"
    assert not (slot / "result.gaoaction").exists()
    assert provider.export_result(identifier, tmp_path / "manual", True)["status"] == completed["status"]
    assert recognizer.calls == 1
