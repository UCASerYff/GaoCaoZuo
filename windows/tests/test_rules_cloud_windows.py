from __future__ import annotations

import hashlib
import os
from copy import deepcopy

import pytest

from gaocaozuo import rules_cloud


def _document_store(rows, provider):
    state = {"schema": 1, "rules": rows}

    def write(document):
        state.clear()
        state.update(deepcopy(document))

    return rules_cloud.RuleCloud(lambda: deepcopy(state), write, provider=provider), state


def _sample_rule():
    return {"id": "fixture", "kind": "action", "actionID": "window.leftHalf", "name": "fixture", "enabled": True}


@pytest.mark.parametrize("name,expected", [
    ("iCloud Drive", True),
    ("iCloud 云盘", True),
    ("iCloudDrive", True),
    ("iCloud Photos", False),
    ("GaoCaoZuo Synthetic CF Provider", False),
    (None, False),
])
def test_icloud_drive_name_identification(monkeypatch, tmp_path, name, expected):
    monkeypatch.setattr(rules_cloud, "_cloud_provider", lambda _folder: name)
    assert rules_cloud._apple_provider(tmp_path) == expected


def test_poll_does_not_recreate_removed_approved_directory(tmp_path):
    sync, document = _document_store([], lambda _folder: True)
    assert sync.configure(str(tmp_path), True)["status"] == "localSynced"
    active = tmp_path / rules_cloud.ROOT_NAME
    active.rename(tmp_path / "moved")
    expected = deepcopy(document)
    assert sync.poll(force=True)["status"] == "cloudPending"
    assert not active.exists()
    assert document == expected


@pytest.mark.skipif(os.name != "nt", reason="Requires Windows Cloud Files API")
def test_unregistered_folder_is_rejected_by_native_cloud_files_api(tmp_path):
    ordinary = tmp_path / "iCloud Drive"
    ordinary.mkdir()
    assert rules_cloud._cloud_provider(ordinary) is None
    assert not rules_cloud._apple_provider(ordinary)


@pytest.mark.skipif(os.name != "nt" or os.environ.get("GAO_CFAPI_ISOLATED_SMOKE") != "1",
                    reason="Opt-in temporary registration of an isolated Windows Cloud Files test root")
def test_cloud_files_registration_and_local_rule_sync(tmp_path):
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.native_win import bind

    class Registration(c.Structure):
        _fields_ = [("Size", w.ULONG), ("Name", w.LPCWSTR), ("Version", w.LPCWSTR),
                    ("RootIdentity", w.LPVOID), ("RootIdentityLength", w.DWORD), ("FileIdentity", w.LPVOID),
                    ("FileIdentityLength", w.DWORD), ("ProviderId", w.BYTE * 16)]

    class Policy(c.Structure):
        _fields_ = [("Primary", w.USHORT), ("Modifier", w.USHORT)]

    class Policies(c.Structure):
        _fields_ = [("Size", w.ULONG), ("Hydration", Policy), ("Population", Policy),
                    ("InSync", w.DWORD), ("HardLink", w.DWORD), ("PlaceholderManagement", w.DWORD)]

    register = bind("CldApi", "CfRegisterSyncRoot", c.c_long, w.LPCWSTR, c.POINTER(Registration), c.POINTER(Policies), w.DWORD)
    unregister = bind("CldApi", "CfUnregisterSyncRoot", c.c_long, w.LPCWSTR)
    name = "GaoCaoZuo Synthetic CF Provider"
    home = tmp_path / "isolated-sync-root"
    home.mkdir()
    assert rules_cloud._cloud_provider(home) is None
    registration = Registration(c.sizeof(Registration), name, "1")
    policies = Policies(c.sizeof(Policies), Policy(3, 0), Policy(3, 0))  # Always-full data and namespace
    registered = register(str(home), c.byref(registration), c.byref(policies), 0)
    assert registered == 0, f"CfRegisterSyncRoot HRESULT=0x{registered & 0xFFFFFFFF:08X}"
    try:
        selection = home / "isolated-selected-folder"
        selection.mkdir()
        assert rules_cloud._cloud_provider(home) == name
        assert rules_cloud._cloud_provider(selection) == name
        assert not rules_cloud._apple_provider(selection)

        # Exercise normal rule I/O with the synthetic registration only in this fixture.
        def provider(path):
            return rules_cloud._cloud_provider(path) == name

        publisher, _ = _document_store([_sample_rule()], provider)
        reader, document = _document_store([], provider)
        assert publisher.configure(str(selection), True)["status"] == "localSynced"
        published = publisher.result["heads"]
        shared = selection / rules_cloud.ROOT_NAME
        revision = shared / f"{published[0]}.json"
        assert rules_cloud._cloud_provider(revision) == name
        assert hashlib.sha256(revision.read_bytes()).hexdigest() == published[0]
        assert list(shared.iterdir()) == [revision]
        assert reader.configure(str(selection), True)["heads"] == published
        assert document["rules"][0] == {**_sample_rule(), "enabled": False, "needsReview": True, "cloudWantsEnabled": True}
        reader.approve("fixture", True, True)
        assert document["rules"] == [_sample_rule()]
    finally:
        status = unregister(str(home))
        assert status == 0, f"CfUnregisterSyncRoot HRESULT=0x{status & 0xFFFFFFFF:08X}"
    assert rules_cloud._cloud_provider(home) is None
    assert reader.poll(force=True)["status"] == "unavailable"
    assert document["rules"] == [_sample_rule()]
    revision.unlink()
    shared.rmdir()
    selection.rmdir()
    home.rmdir()
