import json
import stat
import zipfile
from pathlib import Path

import pytest

from gaocaozuo.app import App
from gaocaozuo.archive import ExtractBatch, build_zip, create_zip, extract_zip, inspect_zip
from gaocaozuo.clipboard import PasteTransaction
from gaocaozuo.errors import AppError, LayoutFailure
from gaocaozuo.features import expand_snippet, merge_configurations, validate_package
from gaocaozuo.files import rename_preview, undo
from gaocaozuo.images import decode_png
from gaocaozuo.layout import LayoutTransaction, Rect, is_window_drag, restore_focus, target_frame
from gaocaozuo.qr import decode_text, encode
from gaocaozuo.system import LOCK_MESSAGE, SAVER_MESSAGE, FakeSystem
from gaocaozuo.version import VERSION_LABEL
from gaocaozuo.web import serve


class ScriptedWindow:
    def __init__(self, frame, max_w=None, max_h=None):
        self.frame = frame
        self.max_w = max_w
        self.max_h = max_h
        self.saved = None

    def validate(self):
        return None

    def validate_rollback(self):
        return None

    def save_original(self, rect):
        self.saved = Rect(rect.x, rect.y, rect.w, rect.h)

    def set_size(self, w, h):
        if self.max_w is not None:
            w = min(w, self.max_w)
        if self.max_h is not None:
            h = min(h, self.max_h)
        self.frame = Rect(self.frame.x, self.frame.y, w, h)

    def set_position(self, x, y):
        self.frame = Rect(x, y, self.frame.w, self.frame.h)

    def read(self):
        return self.frame


def test_version_label():
    assert VERSION_LABEL == "1.16+6"


def test_settings_preserve_unknown_and_refuse_newer(tmp_path):
    path = tmp_path / "settings.json"
    original = {"schema": 1, "appearance": "system", "language": "zh-Hans", "windowEnhancements": {"kept": True}, "clipboardEnabled": False, "clipboardDays": 7, "clipboardLimit": 200, "clipboardExcludedApps": [], "favorites": ["new.text"], "folders": [], "templates": [], "snippets": [], "workflows": [], "cleanerDurationSeconds": 180, "localLock": {"schema": 1, "enabled": False, "idleSeconds": 300, "warningSeconds": 15, "action": "lockScreen"}}
    path.write_text(json.dumps(original), encoding="utf-8")
    app = App(tmp_path)
    app.toggle = app.store.toggle_favorite("path.copy")
    saved = json.loads(path.read_text(encoding="utf-8"))
    assert saved["windowEnhancements"] == {"kept": True}
    assert saved["favorites"] == ["new.text", "path.copy"]
    newer = tmp_path / "newer"
    newer.mkdir()
    target = newer / "settings.json"
    payload = b'{"schema": 2, "secret": "keep-me"}'
    target.write_bytes(payload)
    blocked = App(newer)
    with pytest.raises(AppError):
        blocked.create_settings()
    assert target.read_bytes() == payload


def test_corrupt_and_foreign_are_not_replaced(tmp_path):
    broken = tmp_path / "broken"
    broken.mkdir()
    target = broken / "settings.json"
    target.write_bytes(b"{")
    app = App(broken)
    with pytest.raises(AppError):
        app.create_settings()
    assert target.read_bytes() == b"{"
    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "notes.txt").write_text("keep", encoding="utf-8")
    other = App(foreign)
    with pytest.raises(AppError) as raised:
        other.create_settings()
    assert "不会用空白设置覆盖" in raised.value.message
    assert not (foreign / "settings.json").exists()


def test_changed_settings_are_not_overwritten(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    path = tmp_path / "settings.json"
    path.write_text('{"schema": 1, "appearance": "dark", "language": "en", "favorites": [], "folders": [], "templates": [], "snippets": [], "workflows": [], "clipboardEnabled": false, "clipboardDays": 7, "clipboardLimit": 200, "clipboardExcludedApps": [], "cleanerDurationSeconds": 180}', encoding="utf-8")
    with pytest.raises(AppError) as raised:
        app.update_settings({"language": "zh-Hans"})
    assert raised.value.code == "conflict"
    assert "dark" in path.read_text(encoding="utf-8")


def test_files_do_not_overwrite_and_rename_preview(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    folder = tmp_path / "work"
    folder.mkdir()
    first = app.perform("new.text", {"directory": str(folder)})
    second = app.perform("new.text", {"directory": str(folder)})
    assert Path(first["path"]).name == "未命名.txt"
    assert Path(second["path"]).name == "未命名 2.txt"
    (folder / "a.txt").write_text("alpha", encoding="utf-8")
    (folder / "b.txt").write_text("beta", encoding="utf-8")
    plans = rename_preview([folder / "a.txt", folder / "b.txt"], "{name}-{n:03}.{ext}", 1)
    assert [Path(item["destination"]).name for item in plans] == ["a-001.txt", "b-002.txt"]
    records = app.perform("files.rename", {"plans": plans})["receipts"]
    assert (folder / "a-001.txt").read_text(encoding="utf-8") == "alpha"
    (folder / "a-001.txt").write_text("changed", encoding="utf-8")
    with pytest.raises(AppError) as raised:
        undo([records[0]], lambda path: path.unlink())
    assert "a-001.txt" in raised.value.message
    assert (folder / "a-001.txt").read_text(encoding="utf-8") == "changed"


def test_copy_conflict_stops(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    source = tmp_path / "source.txt"
    source.write_text("one", encoding="utf-8")
    destination = tmp_path / "dest"
    destination.mkdir()
    (destination / "source.txt").write_text("existing", encoding="utf-8")
    with pytest.raises(AppError) as raised:
        app.perform("files.copy", {"paths": [str(source)], "destination": str(destination)})
    assert str(destination / "source.txt") in raised.value.message
    assert (destination / "source.txt").read_text(encoding="utf-8") == "existing"


def test_office_templates_have_empty_author_and_no_macros(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    folder = tmp_path / "docs"
    folder.mkdir()
    created = app.perform("file.new.docx", {"directory": str(folder)})
    blob = Path(created["path"]).read_bytes()
    assert b"vbaProject" not in blob
    with zipfile.ZipFile(created["path"]) as package:
        core = package.read("docProps/core.xml")
    assert b"<dc:creator></dc:creator>" in core
    assert b"TargetMode=\"External\"" not in blob


def test_png_and_bmp_conversion(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    width, height, rgb = 2, 2, bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    source = tmp_path / "sample.bmp"
    from gaocaozuo.images import encode_bmp

    source.write_bytes(encode_bmp(width, height, rgb))
    result = app.perform("images.png", {"paths": [str(source)], "maxEdge": 1})
    converted = Path(result["paths"][0]).read_bytes()
    w, h, out = decode_png(converted)
    assert (w, h) == (1, 1)
    assert source.exists()
    from PIL import Image

    jpeg = app.perform("images.jpeg", {"paths": [str(source)]})["paths"][0]
    with Image.open(jpeg) as image:
        assert image.format == "JPEG" and image.size == (2, 2)


def test_qr_roundtrip():
    text = "搞操作 HELLO"
    assert decode_text(encode(text)) == text
    with pytest.raises(AppError):
        encode("x" * 214)


def test_zip_password_safety_and_batch(tmp_path):
    plain = tmp_path / "plain.txt"
    plain.write_text("public", encoding="utf-8")
    secret = tmp_path / "secret.txt"
    secret.write_text("hidden", encoding="utf-8")
    open_zip = tmp_path / "open.zip"
    locked = tmp_path / "locked.zip"
    create_zip([plain], open_zip)
    create_zip([secret], locked, "密码")
    with zipfile.ZipFile(locked) as package:
        assert package.read("secret.txt", pwd="密码".encode()) == b"hidden"
    slipped = tmp_path / "bad.zip"
    with zipfile.ZipFile(slipped, "w") as package:
        package.writestr("../escaped.txt", b"no")
    with pytest.raises(AppError) as raised:
        extract_zip(slipped, tmp_path / "out-slip")
    assert "越界" in raised.value.message
    assert not (tmp_path / "escaped.txt").exists()
    linked = tmp_path / "link.zip"
    with zipfile.ZipFile(linked, "w") as package:
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        package.writestr(info, b"target")
    with pytest.raises(AppError):
        inspect_zip(linked)
    bomb = tmp_path / "bomb.zip"
    bomb.write_bytes(build_zip([("big.txt", b"0123456789abcdef")]))
    with pytest.raises(AppError) as raised:
        extract_zip(bomb, tmp_path / "too-big", max_bytes=8)
    assert raised.value.code == "budget"
    batch = ExtractBatch()
    calls = {"count": 0}

    def destination_for(archive):
        return tmp_path / (archive.stem + "-out")

    def password_for(archive, incorrect):
        calls["count"] += 1
        return "密码" if archive.name == "locked.zip" else None

    first = batch.run([locked, open_zip], destination_for, password_for)
    assert Path(first["items"][0]["destination"], "secret.txt").read_text(encoding="utf-8") == "hidden"
    again = batch.run([locked, open_zip], destination_for, password_for)
    assert all(item["skipped"] for item in again["items"])
    assert calls["count"] == 1


def test_clipboard_history_stays_unread_until_enabled(tmp_path):
    app = App(tmp_path)
    app.create_settings()
    history = tmp_path / "Clipboard"
    history.mkdir()
    (history / "history.json").write_text(json.dumps({"schema": 1, "items": [{"text": "secret-paste", "date": "2099-01-01T00:00:00+00:00", "pinned": False}]}), encoding="utf-8")
    closed = App(tmp_path)
    assert closed.clipboard.read_attempts == 0
    assert "secret-paste" not in json.dumps(closed.snapshot())
    closed.update_settings({"clipboardEnabled": True})
    assert closed.clipboard.read_attempts == 1
    assert closed.clipboard.search("secret")[0]["text"] == "secret-paste"
    closed.clipboard.remember("from-1password", "com.1password.1password")
    assert all(item["text"] != "from-1password" for item in closed.clipboard.items)


def test_paste_waits_for_the_user_and_merges_stack():
    transaction = PasteTransaction(3, {"text": "old", "parts": [{"kind": "text", "text": "old"}]}, False)
    assert transaction.permits_temporary(3, True)
    transaction.installed_temporary(4)
    transaction.submitted(4, True)
    assert transaction.phase == "awaitingUser"
    with pytest.raises(AppError):
        transaction.record_enter("Edit", True)
    transaction.begin_completion()
    transaction.completed()
    app_dir = None
    from pathlib import Path
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        app = App(Path(directory))
        app.create_settings()
        app.clipboard.set_plain("original")
        app.perform("clipboard.pasteplain", {"text": "incoming", "sendEnter": True, "targetMatches": True})
        with pytest.raises(AppError):
            app.perform("clipboard.pasteplain", {"text": "another", "targetMatches": True})
        app.clipboard.push_stack([
            {"kind": "text", "text": "甲"},
            {"kind": "image", "path": "a.png"},
            {"kind": "file", "path": "b.txt"},
            {"kind": "folder", "path": "c"},
        ])
        app.clipboard.enter("Edit", True)
        assert app.clipboard.transaction.enter_was_submitted
        app.clipboard.confirm()
        assert [part["kind"] for part in app.clipboard.snapshot["parts"]] == ["text", "image", "file", "folder"]
        assert app.clipboard.transaction is None


def test_snippet_variables_skip_clipboard_during_secure_input(tmp_path):
    from datetime import datetime

    assert expand_snippet("今天{date} {clipboard}", datetime(2026, 11, 15, 8, 0, 0), "应忽略", "abc", True) == "今天2026-11-15 "
    app = App(tmp_path)
    app.create_settings()
    saved = app.snippets.save_snippet({"name": "问候", "text": "你好{name}", "shortcut": "hi", "tags": ["日常"], "group": "默认"})
    with pytest.raises(AppError):
        app.snippets.save_snippet({"name": "重复", "text": "x", "shortcut": "hi"})
    table = app.snippets.export_xlsx()
    with zipfile.ZipFile(__import__("io").BytesIO(table)) as package:
        assert "问候" in package.read("xl/worksheets/sheet1.xml").decode("utf-8")
    assert saved["shortcut"] == "hi"


def test_window_layout_rolls_back_when_restore_is_not_exact():
    screen = Rect(0, 0, 1920, 1080)
    current = Rect(100, 80, 800, 600)
    assert target_frame("leftHalf", current, [screen]) == Rect(0, 0, 960, 1080)
    backend = ScriptedWindow(Rect(100, 80, 800, 600))
    outcome = LayoutTransaction().execute(Rect(0, 0, 960, 1080), current, screen, True, True, backend)
    assert outcome["exact"]
    assert backend.saved == current
    limited = ScriptedWindow(current, max_h=600)
    with pytest.raises(LayoutFailure) as raised:
        LayoutTransaction().execute(Rect(0, 0, 960, 1080), current, screen, True, False, limited)
    assert raised.value.rollback_verified
    invalid = ScriptedWindow(current)
    with pytest.raises(AppError):
        LayoutTransaction().execute(Rect(0, 0, 0, 10), current, screen, True, True, invalid)
    assert invalid.saved is None
    with pytest.raises(AppError):
        restore_focus(5, 5, lambda: 5, lambda: None, lambda: None, lambda: True)
    assert is_window_drag(current, Rect(120, 80, 800, 600), 10, 0)


def test_workflow_stops_and_keeps_completed_steps():
    calls = []

    def invoke(step):
        calls.append(step["actionID"])
        if step["actionID"] == "stop":
            raise AppError("第二步失败", "invalid")
        return "ok"

    from gaocaozuo.features import run_workflow

    result = run_workflow([{"actionID": "one"}, {"actionID": "stop"}, {"actionID": "three"}], invoke)
    assert result["stopped"]
    assert [item["actionID"] for item in result["completed"]] == ["one"]
    assert calls == ["one", "stop"]


def test_lock_is_not_reported_as_confirmed(tmp_path):
    system = FakeSystem()
    app = App(tmp_path, system=system)
    app.create_settings()
    result = app.perform("system.lock", {})
    assert result["confirmedLocked"] is False
    assert result["message"] == LOCK_MESSAGE
    saver = app.perform("system.screenSaver", {})
    assert saver["confirmedLocked"] is False
    assert saver["message"] == SAVER_MESSAGE
    idle = app.perform("lock.settings", {"idleSeconds": 10000})
    assert idle["idle"]["requested"] is False
    app.update_settings({"localLock": {"schema": 1, "enabled": True, "idleSeconds": 300, "warningSeconds": 15, "action": "lockScreen"}})
    requested = app.perform("lock.settings", {"idleSeconds": 300})
    assert requested["idle"]["confirmedLocked"] is False
    repeated = app.perform("lock.settings", {"idleSeconds": 300})
    assert repeated["idle"]["requested"] is False
    with pytest.raises(AppError):
        app.update_settings({"localLock": {"schema": 1, "enabled": True, "idleSeconds": 300, "warningSeconds": 15, "action": "lockScreen", "password": "no"}})


def test_handoff_ticket_and_payload_review():
    from gaocaozuo.features import Handoff

    handoff = Handoff(ttl_seconds=10)
    token = handoff.issue("files.copy", [r"C:\secret\a.txt"], now=1)
    assert handoff.consume(token, now=2)["action"] == "files.copy"
    with pytest.raises(AppError):
        handoff.consume(token, now=2)
    url = "gaocaozuo://run?action=files.move&path=C%3A%5Csecret%5Cb.txt"
    review = handoff.submit_payload_url(url)
    assert review["executed"] is False
    approved = handoff.approve(review["reviewID"])
    assert approved["executed"] is True
    redacted = handoff.redact(token + " " + url + " " + r"C:\secret\b.txt")
    assert token not in redacted
    assert r"C:\secret\b.txt" not in redacted
    package = {
        "schemaVersion": 1,
        "kind": "request",
        "requestID": "8b2d6c2e-3e0a-4f4e-9c1a-6d0e2f4a7b11",
        "sourceBundleID": "com.example.Source",
        "targetBundleID": "com.gaoseries.GaoCaoZuo",
        "action": "files.copy",
        "createdAt": "2026-11-15T00:00:00Z",
        "expiresAt": "2026-11-16T00:00:00Z",
        "nonce": "abc",
        "items": [{"path": "notes.txt"}],
        "parameters": {"useDuplicateFileEngine": True, "duplicateFileEngine": False},
    }
    with pytest.raises(AppError):
        validate_package(package, "2026-11-15T01:00:00Z")
    package["parameters"]["useDuplicateFileEngine"] = False
    opened = validate_package(package, "2026-11-15T01:00:00Z")
    assert opened["completed"] is False


def test_input_rules_require_review_for_semantic_changes(tmp_path):
    app = App(tmp_path)
    app.save_rules([
        {"id": "a", "name": "打开", "shortcut": "Ctrl+Alt+O", "actionID": "panel.show", "enabled": True, "include": [], "exclude": []},
    ])
    with pytest.raises(AppError):
        app.save_rules([
            {"id": "a", "shortcut": "Ctrl+Alt+O", "actionID": "panel.show", "enabled": True, "include": [], "exclude": []},
            {"id": "b", "shortcut": "Ctrl+Alt+O", "actionID": "new.text", "enabled": True, "include": [], "exclude": []},
        ])
    remote = [
        {"id": "a", "name": "打开", "shortcut": "Ctrl+Alt+P", "actionID": "panel.show", "enabled": True, "include": [], "exclude": [], "script": "", "kind": "action"},
        {"id": "gone", "name": "旧", "shortcut": "Ctrl+1", "actionID": "new.text", "enabled": True, "include": [], "exclude": [], "script": "", "kind": "action"},
    ]
    imported = app.import_input(remote, ["gone"])
    pending_ids = [item["id"] for item in imported["pending"]]
    assert pending_ids == ["a"]
    assert imported["pending"][0]["enabled"] is False
    assert all(item["id"] != "gone" for item in imported["accepted"] + imported["pending"])
    merged = merge_configurations([{"id": "a"}], [{"id": "a", "actionID": "local"}], [{"id": "a", "actionID": "remote"}])
    assert merged["conflicts"] == ["rules"]
    assert merged["value"] == [{"id": "a", "actionID": "local"}]


def test_screenshot_requires_explicit_confirmation(tmp_path):
    app = App(tmp_path)
    calls = {"count": 0}

    def backend():
        calls["count"] += 1
        return 2, 2, bytes([1, 2, 3] * 4)

    with pytest.raises(AppError):
        app.perform("screenshot.capture", {"confirm": False, "backend": backend})
    assert calls["count"] == 0
    captured = app.perform("screenshot.capture", {"confirm": True, "backend": backend})
    assert captured["saved"] is None
    assert not (tmp_path / "ScreenshotHistory").exists()
    with pytest.raises(AppError):
        app.perform("screenshot.ocr.capture", {})
    assert app.perform("screenshot.recording", {}) == {"section": "screenshots", "show": True}
    assert app.perform("screenshot.translate.clipboard", {}) == {"section": "screenshots", "show": True}


def test_local_http_creates_a_file_and_shuts_down(tmp_path):
    app = App(tmp_path)
    server = serve(app, port=0, open_browser=False)
    try:
        import urllib.request

        page = urllib.request.urlopen(server.url, timeout=5)
        body = page.read().decode("utf-8")
        assert page.status == 200
        assert "搞操作" in body
        token = body.split('name="gao-token" content="', 1)[1].split('"', 1)[0]
        def post(path, payload):
            request = urllib.request.Request(
                server.url.rstrip("/") + path,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json", "X-Gao-Token": token},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.loads(response.read().decode("utf-8"))

        created = post("/api/settings/create", {})
        assert created["ok"]
        folder = tmp_path / "out"
        folder.mkdir()
        made = post("/api/action", {"id": "new.text", "payload": {"directory": str(folder)}})
        assert Path(made["result"]["path"]).read_bytes() == b""
        denied = urllib.request.Request(server.url + "api/state")
        try:
            urllib.request.urlopen(denied, timeout=5)
            assert False
        except urllib.error.HTTPError as exc:
            assert exc.code == 403
        post("/api/shutdown", {})
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()
