import builtins
import json
import os
import socket
import subprocess
from pathlib import Path
from urllib.request import ProxyHandler, Request, build_opener

import pytest

from gaocaozuo.errors import AppError
from gaocaozuo.rule_preview import preview_rule


ACTIVE = {"windowsAutomationEnabled": True}


def _binding(**changes):
    return {"id": "sample-rule", "enabled": True, "shortcut": "Ctrl+Alt+F9", "actionID": "window.leftHalf", **changes}


def _input(rule, sample=None, *, others=(), settings=ACTIVE):
    return preview_rule({"ruleID": rule["id"], "sample": sample or {}}, rules=[rule, *others], workflows=[], settings=settings)


def _workflow(actions, sample=None):
    workflow = {"id": "sample-workflow", "steps": [{"actionID": action} for action in actions]}
    return preview_rule({"kind": "workflow", "workflowID": workflow["id"], "sample": sample or {}},
                        rules=[], workflows=[workflow], settings={})


def test_rule_uses_live_trigger_aliases_and_scope_rules_without_binding_windows():
    rule = _binding(include=["NOTEPAD.EXE", "paint.exe"], exclude=["paint.exe"])
    report = _input(rule, {"application": r"C:\Sample\Notepad.exe", "shortcut": "Control+Option+f9"})
    assert report["readOnly"] and not report["executed"] and report["matched"]
    assert report["outcome"] == "planned"
    assert report["steps"][0]["effects"] == [{"kind": "action", "operation": "左半屏"}]
    assert report["steps"][0]["uncertainty"]
    assert _input(rule, {"application": "paint.exe"})["outcome"] == "notMatched"
    assert _input(rule, {"application": "Notepad.exe", "shortcut": "Alt+F9"})["outcome"] == "notMatched"


@pytest.mark.parametrize(("changes", "match", "mismatch"), [
    ({"trigger": "mouseButton", "mouseButton": 3, "mouseModifiers": "Ctrl"},
     {"trigger": "mouseButton", "mouseButton": 3, "mouseModifiers": "Control"},
     {"trigger": "mouseButton", "mouseButton": 4, "mouseModifiers": "Control"}),
    ({"trigger": "gesture", "direction": "left", "mouseModifiers": "Alt"},
     {"trigger": "gesture", "direction": "left", "mouseModifiers": "Option"},
     {"trigger": "gesture", "direction": "right", "mouseModifiers": "Option"}),
])
def test_mouse_and_gesture_samples_share_the_runtime_trigger_representation(changes, match, mismatch):
    rule = _binding(**changes)
    assert _input(rule, match)["outcome"] == "planned"
    assert _input(rule, mismatch)["outcome"] == "notMatched"
    assert _input(rule, {"trigger": "unknown"})["outcome"] == "blocked"


def test_inactive_unreviewed_and_duplicate_bindings_show_blockers_and_hypothetical_action():
    rule = _binding(application="notepad.exe")
    peer = _binding(id="another-rule", application="notepad.exe", actionID="window.rightHalf")
    sample = {"application": "notepad.exe"}
    collision = _input(rule, sample, others=[peer])
    assert collision["matched"] and collision["outcome"] == "blocked"
    assert collision["steps"][0]["status"] == "blocked" and "多条启用规则" in collision["steps"][0]["reason"]
    assert collision["steps"][0]["effects"]
    assert _input(rule, sample, others=[{**peer, "needsReview": True}])["outcome"] == "planned"
    assert _input(rule, sample, settings={})["steps"][0]["reason"] == "输入监听已关闭或暂停。"
    assert _input({**rule, "needsReview": True}, sample)["steps"][0]["reason"] == "规则仍待复核。"


def test_rules_outside_runtime_loading_limit_are_blocked():
    early = [_binding(id=f"rule-{number}", enabled=False) for number in range(512)]
    late = _binding()
    report = preview_rule({"ruleID": late["id"]}, rules=[*early, late], workflows=[], settings=ACTIVE)
    assert report["matched"] and report["outcome"] == "blocked"
    assert report["steps"][0]["reason"] == "规则超出 Windows 的加载范围。"


def test_input_dry_run_cannot_provide_real_file_selection_or_confirmation_to_runtime():
    native = _input(_binding(actionID="archive.create"), {"paths": [r"C:\Sample\photo.png"]})
    assert native["outcome"] == "blocked" and "不会收到文件选择" in native["steps"][0]["reason"]
    report = preview_rule({"rule": _binding(actionID="window.close"), "confirm": True}, rules=[], workflows=[], settings=ACTIVE)
    assert report["outcome"] == "blocked" and "确认" in report["steps"][0]["reason"]
    assert report["steps"][0]["effects"] == []


def test_workflow_preview_stops_after_blocked_step_and_numbers_known_file_conflicts():
    report = _workflow(["archive.create", "images.png", "archive.extract", "window.leftHalf"],
                       {"paths": [r"C:\sample\report.JPEG"], "existingPaths": [r"c:\SAMPLE\Report.zip", r"C:\sample\report.png"]})
    assert report["outcome"] == "blocked" and report["matched"]
    assert [step["status"] for step in report["steps"]] == ["planned", "planned", "blocked", "skipped"]
    assert [step["index"] for step in report["steps"]] == [1, 2, 3, 4]
    assert report["steps"][0]["effects"][0]["path"] == r"C:\sample\report 2.zip"
    assert report["steps"][1]["effects"][0]["path"] == r"C:\sample\report 2.png"
    assert report["steps"][3]["effects"] == []


def test_split_archive_estimate_lists_one_folder_and_flags_unverified_contents():
    report = _workflow(["archive.extract", "archive.extract"], {"paths": [r"C:\sample\a.zip.001", r"C:\sample\a.zip.002"]})
    step = report["steps"][0]
    assert report["outcome"] == "planned"
    assert step["effects"] == [{"kind": "file", "operation": "创建解压目录", "path": r"C:\sample\a", "source": r"C:\sample\a.zip.001"}]
    assert "分卷" in step["uncertainty"]
    assert report["steps"][1]["effects"] == [{"kind": "action", "operation": "沿用前一步的解压结果", "path": r"C:\sample\a", "source": r"C:\sample\a.zip.001"}]
    independent = _workflow(["archive.extract"], {"paths": [r"C:\sample\a.zip", r"C:\sample\a.zip.001"]})
    assert [item["path"] for item in independent["steps"][0]["effects"]] == [r"C:\sample\a", r"C:\sample\a 2"]


def test_custom_archive_uses_the_live_workflow_default_and_blocks_duplicate_source_names():
    report = _workflow(["archive.custom"], {"paths": [r"C:\sample\file.txt"], "format": "7z"})
    assert report["steps"][0]["effects"][0]["path"] == r"C:\sample\file.zip"
    conflict = _workflow(["archive.custom"], {"paths": [r"C:\sample\file.txt", r"D:\sample\FILE.txt"]})
    assert conflict["outcome"] == "blocked" and not conflict["steps"][0]["effects"]


@pytest.mark.parametrize(("action", "title"), [("delay", "等待"), ("open.path", "打开路径"), ("open.url", "打开网址")])
def test_legacy_workflow_placeholders_are_named_and_blocked_when_runtime_has_no_handler(action, title):
    report = _workflow([action, "system.lock"])
    assert [step["status"] for step in report["steps"]] == ["blocked", "skipped"]
    assert report["steps"][0]["title"] == title and "Windows" in report["steps"][0]["reason"]


def test_preview_never_reads_paths_dispatches_actions_or_accesses_external_state(monkeypatch):
    def forbidden(*_args, **_kwargs):
        raise AssertionError("preview attempted a real effect")

    with monkeypatch.context() as guard:
        for module, name in [(builtins, "open"), (os, "stat"), (os, "lstat"), (os, "mkdir"), (Path, "open"),
                             (Path, "iterdir"), (subprocess, "Popen"), (socket, "socket")]:
            guard.setattr(module, name, forbidden)
        report = _workflow(["archive.7z", "images.bmp", "path.copy", "system.lock"],
                           {"paths": [r"\\hypothetical-host\share\input.png"]})
    assert report["outcome"] == "planned" and not report["executed"]
    assert [effect["kind"] for step in report["steps"] for effect in step["effects"]] == ["file", "file", "action", "action"]


@pytest.mark.parametrize("path", ["relative.txt", r"C:\sample\..\file.txt", r"C:\sample\COM1", r"\\?\C:\sample\file.txt"])
def test_invalid_windows_fixture_spelling_is_refused(path):
    with pytest.raises(AppError) as rejected:
        _workflow(["images.png"], {"paths": [path]})
    assert rejected.value.code == "invalid"


def test_loopback_preview_does_not_dispatch_or_refresh_live_application_state(tmp_path, monkeypatch):
    from gaocaozuo.app import App
    from gaocaozuo.web import serve

    root = tmp_path / "synthetic"
    app = App(root)
    app.create_settings()
    app.update_settings(ACTIVE)
    rule = _binding(application="notepad.exe")
    app.save_rules([rule])
    approved = (root / "Input" / "rules.json").read_bytes()

    def forbidden(*_args, **_kwargs):
        raise AssertionError("preview touched the live action or state gateway")

    monkeypatch.setattr(app, "perform", forbidden)
    monkeypatch.setattr(app, "snapshot", forbidden)
    server = serve(app, open_browser=False)
    try:
        payload = {"ruleID": rule["id"], "sample": {"application": "notepad.exe"}, "confirm": True}
        request = Request(server.url + "api/rules/preview", json.dumps(payload).encode(),
                          {"X-Gao-Token": server.token, "Content-Type": "application/json"})
        with build_opener(ProxyHandler({})).open(request, timeout=3) as response:
            report = json.load(response)
        assert report["ok"] and "state" not in report
        assert report["result"]["outcome"] == "planned" and not report["result"]["executed"]
        assert (root / "Input" / "rules.json").read_bytes() == approved
    finally:
        server.shutdown()
        server.server_close()
