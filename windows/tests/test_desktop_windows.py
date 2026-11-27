import ctypes as c
import ctypes.wintypes as w
import os
import queue
import threading
import time
import uuid

import pytest

from gaocaozuo.desktop_win import WindowsDesktop
from gaocaozuo.errors import AppError
from gaocaozuo.features import needs_review, shortcut_conflicts
from gaocaozuo.native_win import kernel, user
from gaocaozuo.rules_win import ALT, CTRL, Binding, direction_between, parse_shortcut
from gaocaozuo.system import IdlePolicy


def test_windows_shortcuts_compare_native_bindings_and_scope():
    left = {"id": "a", "enabled": True, "actionID": "window.leftHalf", "shortcut": "Control + Alt + W", "application": "Notepad.exe"}
    right = {**left, "id": "b", "shortcut": "Alt+CTRL+w", "application": r"C:\Windows\notepad.EXE"}
    assert parse_shortcut("Control + Alt + W") == (ALT | CTRL, ord("W"))
    assert parse_shortcut("Shift+W") is None
    assert parse_shortcut("Ctrl+F12") is None
    assert shortcut_conflicts([left, right]) == [("a", "b")]
    assert shortcut_conflicts([left, {**right, "application": "explorer.exe"}]) == []
    assert Binding.from_rule(left).matches("NOTEPAD.EXE")
    assert not Binding.from_rule(left).matches("explorer.exe")
    assert Binding.from_rule({**left, "application": True}) is None
    gesture = {"id": "a", "enabled": True, "actionID": "window.leftHalf", "trigger": "gesture", "direction": "left"}
    assert Binding.from_rule(gesture).key == ("gesture", ALT, "left")
    assert needs_review(gesture, {**gesture, "direction": "right"})
    assert direction_between((0, 0), (-100, -20)) == "left"
    assert direction_between((0, 0), (100, 100)) is None


def test_native_idle_does_not_dispatch_a_stale_or_invisible_warning():
    policy = IdlePolicy({"enabled": True, "idleSeconds": 30, "warningSeconds": 5})
    moment = 0
    timestamp = 1
    start = -10
    safe = True
    show = True
    calls = []

    def sample(at):
        nonlocal moment
        moment = at
        policy.sample(lambda: (timestamp, moment - start), lambda: None if safe else "正在录制",
                      lambda warning: show or warning is None,
                      lambda action: calls.append(action) or {"message": "已提交"}, lambda: moment)

    for step in range(0, 31):
        sample(step)
    assert policy.snapshot()["state"] == "countdown"
    assert policy.snapshot()["remaining"] == 5
    sample(39)  # long polling gap discards the old deadline
    assert policy.snapshot()["state"] == "observing"
    assert calls == []
    show = False
    for step in range(40, 70):
        sample(step)
    assert policy.snapshot()["state"] == "paused"
    assert calls == []
    show = True
    for step in range(70, 103):
        sample(step)
    safe = False
    sample(103)
    assert policy.snapshot()["state"] == "paused"
    assert calls == []
    safe = True
    for step in range(104, 142):
        sample(step)
    assert calls == ["lockScreen"]
    assert policy.snapshot()["state"] == "waitingForActivity"
    timestamp, start = 2, 142
    sample(142)
    assert policy.snapshot()["state"] == "observing"
    assert calls == ["lockScreen"]


@pytest.mark.skipif(os.name != "nt", reason="requires Windows message queues")
def test_runtime_starts_and_releases_resources_without_interaction():
    from gaocaozuo.runtime_win import WindowsRuntime
    from gaocaozuo.system import FakeSystem, SystemGateway

    class NoUserWindows:
        def observe_foreground(self):
            return None

    observed = threading.Event()
    actions = []
    runtime = WindowsRuntime(NoUserWindows(), SystemGateway(FakeSystem()), IdlePolicy({"enabled": False}),
                             lambda *action: actions.append(action), on_tick=observed.set)
    runtime.configure([], paused=True)
    runtime.start()
    try:
        assert observed.wait(3)
        assert runtime.snapshot()["running"]
        assert actions == []
    finally:
        runtime.close()
    assert not runtime.snapshot()["running"]


@pytest.mark.skipif(os.name != "nt", reason="requires Windows message queues")
def test_disabled_tray_owns_only_a_hidden_window():
    from gaocaozuo.tray_win import WindowsTray

    calls = []
    tray = WindowsTray(lambda: calls.append("show"), lambda: calls.append("exit"))
    tray.configure(False)
    tray.start()
    try:
        assert tray.ready.wait(3)
        assert tray._window
        assert not user("IsWindowVisible", w.BOOL, w.HWND)(tray._window)
        assert not tray.registered
        assert calls == []
    finally:
        tray.close()
    assert tray._window is None


@pytest.mark.skipif(os.name != "nt", reason="requires Windows desktop APIs")
def test_verified_window_geometry_on_a_separate_windows_desktop(monkeypatch):
    # Neither this thread nor Windows switches to the new desktop for input.
    create_desktop = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)
    handle = create_desktop("GaoOperationTest-" + uuid.uuid4().hex, None, None, 0, 0x000F01FF, None)
    if not handle:
        pytest.skip(f"this session does not allow isolated Win32 desktops ({c.get_last_error()})")
    out = queue.Queue()

    def exercise(hwnd):
        try:
            assert user("SetThreadDesktop", w.BOOL, w.HANDLE)(handle)
            desktop = WindowsDesktop()
            desktop._is_own = lambda *_: False  # this process owns the fixture
            with pytest.raises(AppError, match="没有可用交互桌面"):
                desktop.overview()
            monkeypatch.setattr("gaocaozuo.desktop_win.is_input_desktop", lambda: True)
            overview = desktop.overview()
            original, = overview["windows"]
            assert original["title"] == "隔离布局测试"
            assert original["hwnd"] == hwnd
            key = original["id"]
            moved = desktop.perform("rightHalf", key)
            assert moved["applied"] and moved["exact"]
            assert moved["actual"]["x"] > original["x"]
            restored = desktop.perform("restore", key)
            expected = {field: original[field] for field in ("x", "y", "width", "height")}
            assert restored["exact"] and restored["actual"] == expected
            assert desktop.perform("minimize", key)["exact"]
            assert desktop.overview()["windows"][0]["minimized"]
            assert desktop.perform("unminimizeAll", key)["exact"]
            assert not desktop.overview()["windows"][0]["minimized"]
            with pytest.raises(AppError, match="明确确认"):
                desktop.perform("close", key)
            out.put(None)
        except BaseException as exc:
            out.put(exc)

    def own_window():
        try:
            assert user("SetThreadDesktop", w.BOOL, w.HANDLE)(handle)
            create_window = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                                 c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
            hwnd = create_window(0, "STATIC", "隔离布局测试", 0x10CF0000, 80, 100, 480, 330, None, None, instance, None)
            assert hwnd
            try:
                tester = threading.Thread(target=exercise, args=(hwnd,), daemon=True)
                tester.start()
                message = w.MSG()
                peek = user("PeekMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT)
                dispatch = user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
                deadline = time.monotonic() + 8
                while tester.is_alive() and time.monotonic() < deadline:
                    while peek(c.byref(message), None, 0, 0, 1):
                        dispatch(c.byref(message))
                    time.sleep(0.01)
                assert not tester.is_alive()
            finally:
                user("DestroyWindow", w.BOOL, w.HWND)(hwnd)
        except BaseException as exc:
            out.put(exc)

    thread = threading.Thread(target=own_window, daemon=True)
    try:
        thread.start()
        thread.join(timeout=10)
        assert not thread.is_alive()
        result = out.get_nowait()
        if result is not None:
            raise result
    finally:
        user("CloseDesktop", w.BOOL, w.HANDLE)(handle)
