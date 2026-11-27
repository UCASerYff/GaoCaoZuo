"""Opt-in native paste and keyboard checks for an initially empty Windows clipboard."""

from __future__ import annotations

import argparse
import ctypes as c
import ctypes.wintypes as w
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from threading import Event

from foreground_screenshot_smoke import REQUIRED_IDLE, wait_until
from gaocaozuo.app import App
from gaocaozuo.capture_win import foreground_window, window_identity
from gaocaozuo.clipboard_win import CF_UNICODETEXT, WindowsClipboard
from gaocaozuo.errors import AppError
from gaocaozuo.native_win import is_input_desktop, is_session_active, kernel, user
from gaocaozuo.platform_win import last_input, send_keys
from gaocaozuo.runtime_win import WindowsRuntime
from gaocaozuo.system import FakeSystem


PAYLOAD = "GaoCaoZuo Ω 合成验证"
PRIVATE_SWITCH = 0x8006


def show_fixture(directory: Path, name: str) -> None:
    callback = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

    class WindowClass(c.Structure):
        _fields_ = [("style", w.UINT), ("procedure", callback), ("class_extra", c.c_int), ("window_extra", c.c_int),
                    ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                    ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]

    original = protected = None
    instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
    default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    set_focus = user("SetFocus", w.HWND, w.HWND)
    create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int, c.c_int,
                  c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
    clipboard = WindowsClipboard()
    count_formats = user("CountClipboardFormats", w.UINT)

    @callback
    def top_window(hwnd, message, first, second):
        if message == PRIVATE_SWITCH:
            set_focus(protected if first else original)
            return 0
        if message == 0x0002:
            user("PostQuitMessage", None, c.c_int)(0)
            return 0
        return default(hwnd, message, first, second)

    previous = {}
    call_original = user("CallWindowProcW", c.c_ssize_t, w.LPVOID, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    key_down = user("GetKeyState", c.c_short, c.c_int)

    @callback
    def edit_window(hwnd, message, first, second):
        # The fixture never delegates paste to EDIT's unguarded native handler. Under the OS clipboard lock,
        # it reads only a sequence proven to have been installed by this test and asserts the synthetic bytes.
        if (message == 0x0100 and first == ord("V") and key_down(0x11) < 0) or message == 0x0302:
            return 0 if hwnd == protected else insert_fixture_text(hwnd)
        if message == 0x0102 and first == 22:
            return 0
        return call_original(previous[hwnd], hwnd, message, first, second)

    def insert_fixture_text(hwnd):
        try:
            expected = int((directory / "sequence.txt").read_text())
            with clipboard.opened():
                if clipboard.sequence() != expected or not count_formats():
                    return 0
                if clipboard.decode_text(clipboard.read_format(CF_UNICODETEXT) or b"") != PAYLOAD:
                    return 0
            value = c.create_unicode_buffer(PAYLOAD)
            call_original(previous[hwnd], hwnd, 0x00C2, 0, c.addressof(value))  # EM_REPLACESEL
            (directory / "pasted.txt").write_text("verified", encoding="ascii")
        except (AppError, OSError, ValueError):
            pass
        return 0

    descriptor = WindowClass(procedure=top_window, instance=instance, name=name)
    if not user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))(c.byref(descriptor)):
        raise RuntimeError("Synthetic clipboard class was rejected.")
    try:
        top = create(0, name, name, 0x00CF0000, 80, 80, 440, 186, None, None, instance, None)
        if not top:
            raise RuntimeError("Synthetic clipboard window was rejected.")
        original = create(0x200, "EDIT", "", 0x50010080, 14, 12, 340, 28, top, None, instance, None)
        protected = create(0x200, "EDIT", "", 0x500100A0, 14, 60, 340, 28, top, None, instance, None)
        if not original or not protected:
            raise RuntimeError("Synthetic edit controls were rejected.")
        subclass = user("SetWindowLongPtrW", c.c_ssize_t, w.HWND, c.c_int, c.c_ssize_t)
        for control in (original, protected):
            previous[control] = subclass(control, -4, c.cast(edit_window, c.c_void_p).value)
            if not previous[control]:
                raise RuntimeError("The fixture could not guard the native EDIT paste handler.")
        user("ShowWindow", w.BOOL, w.HWND, c.c_int)(top, 1)
        user("SetForegroundWindow", w.BOOL, w.HWND)(top)
        set_focus(original)
        (directory / "controls.json").write_text(json.dumps([top, original, protected]), encoding="utf-8")
        message = w.MSG()
        while user("GetMessageW", c.c_int, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)(c.byref(message), None, 0, 0) > 0:
            user("TranslateMessage", w.BOOL, c.POINTER(w.MSG))(c.byref(message))
            user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))(c.byref(message))
    finally:
        user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(name, instance)


def exercise(directory: Path, verify_paste=True) -> dict:
    if not is_input_desktop() or not is_session_active():
        raise RuntimeError("The session is not the active ordinary Windows input desktop.")
    start_tick, idle = last_input()
    if idle < REQUIRED_IDLE:
        raise RuntimeError(f"User activity was detected {idle:.1f}s ago; the clipboard was not touched.")
    count = user("CountClipboardFormats", w.UINT)
    app = App(directory / "app-data", interactive=True, system=FakeSystem())
    native = app.native_clipboard
    empty_sequence = None
    if verify_paste:
        with native.opened():
            if count():
                raise RuntimeError("The existing clipboard contains formats. Its contents were not read.")
            empty_sequence = native.sequence()
    test_sequence = None
    result = {}
    process = top = runtime = None
    name = f"GaoCaoZuoSyntheticClipboard_{os.getpid()}_{time.monotonic_ns()}"
    previous_foreground = foreground_window()
    post = user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    original_formats = native.formats
    original_replace = native.replace
    planned = native.plain_formats(PAYLOAD, temporary=True)

    def require_empty():
        if native.sequence() != empty_sequence or count():
            raise AppError("The existing clipboard changed. Its contents were not read.", "changed")
        return original_formats()

    def replace_test_data(formats, expected=None, fallback=None):
        nonlocal test_sequence
        if formats not in ({}, planned) or expected not in (empty_sequence, test_sequence) or expected is None:
            raise AppError("Unexpected clipboard replacement was suppressed.", "changed")
        sequence = original_replace(formats, expected, fallback)
        if formats:
            test_sequence = sequence
            (directory / "sequence.txt").write_text(str(sequence), encoding="ascii")
        return sequence

    native.formats = require_empty
    native.replace = replace_test_data
    try:
        if last_input()[0] != start_tick:
            raise RuntimeError("New user activity arrived before the fixture launched.")
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--child", str(directory), name],
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        startup = directory / "controls.json"
        if not wait_until(lambda: startup.exists() and startup.stat().st_size > 0):
            raise RuntimeError("Synthetic clipboard controls did not initialize.")
        top, original, protected = json.loads(startup.read_text(encoding="utf-8"))
        identity = window_identity(top)
        if identity is None or identity.pid != process.pid or identity.class_name != name:
            raise RuntimeError("The clipboard target is not the expected synthetic process.")
        if last_input()[0] != start_tick or foreground_window() != top or native.focus_details(top) != (original, False, True):
            raise RuntimeError("The synthetic edit field is not safely in the foreground.")
        target = app.desktop._id_for(identity)
        if verify_paste:
            submitted = app.perform("clipboard.pasteplain", {"text": PAYLOAD, "targetID": target, "sendEnter": True})
            assert submitted["phase"] == "awaitingUser" and submitted["eventWasSubmitted"] and not submitted["automaticEnter"], submitted
            assert wait_until((directory / "pasted.txt").is_file), "The synthetic control did not consume the temporary clipboard."
            confirmed = app.clipboard.confirm()
            assert confirmed["restored"] and not confirmed["enterSubmitted"] and not count(), confirmed
            result.update(pasteConsumed=True, restoredEmptyClipboard=True, automaticEnter=False)
            empty_sequence = native.sequence()
        app.desktop.require_foreground(identity)
        assert post(top, PRIVATE_SWITCH, 1, 0) and wait_until(lambda: native.focus_details(top) == (protected, True, True))
        before = native.sequence() if verify_paste else None
        try:
            app.perform("clipboard.pasteplain", {"text": PAYLOAD, "targetID": target})
        except AppError as exc:
            assert exc.code == "blocked", exc
        else:
            raise AssertionError("A password-style edit field unexpectedly accepted automated paste.")
        if verify_paste:
            assert native.sequence() == before and not count()
        result["protectedPasteBlocked"] = True

        fired = Event()
        runtime = WindowsRuntime(app.desktop, app.system, app.idle,
                                 lambda key, payload: fired.set() if key == "panel.show" and payload.get("nativeTarget") == identity else None)
        runtime.configure([{"id": "qa", "shortcut": "Ctrl+Shift+F21", "application": identity.application,
                            "actionID": "panel.show", "enabled": True}])
        runtime.start()
        ready = wait_until(lambda: runtime.snapshot()["rules"][0]["status"] == "active", 2)
        app.desktop.require_foreground(identity)
        if not ready:
            raise RuntimeError(f"Protected paste was blocked, but the synthetic hotkey did not register: {runtime.snapshot()['rules']}.")
        if not send_keys((0x11, 0x10, 0x84), expected_window=top):
            raise RuntimeError("Protected paste was blocked, but Windows refused to submit the synthetic hotkey.")
        if not fired.wait(2):
            raise RuntimeError(f"Protected paste was blocked and Windows accepted the synthetic input, but the action was not received: {runtime.snapshot()['lastAction']}.")
        result["syntheticRegisteredHotkey"] = True
        return result
    finally:
        if runtime:
            runtime.close()
        if test_sequence is not None and native.sequence() == test_sequence:
            try:
                original_replace({}, test_sequence)
            except AppError:
                pass
        if process:
            owned = window_identity(top) if top else None
            was_foreground = owned is not None and owned.pid == process.pid and foreground_window() == top
            if owned is not None and owned.pid == process.pid and owned.class_name == name:
                post(top, 0x0010, 0, 0)
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(3)
            if was_foreground and previous_foreground and foreground_window() in (0, top):
                user("SetForegroundWindow", w.BOOL, w.HWND)(previous_foreground)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--input-only", action="store_true", help="Check protected-paste rejection and hotkey delivery without opening the clipboard.")
    parser.add_argument("--child", nargs=2, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required.")
    if arguments.child:
        show_fixture(Path(arguments.child[0]), arguments.child[1])
    elif arguments.run:
        try:
            with tempfile.TemporaryDirectory(prefix="gaocaozuo-private-paste-test-") as path:
                print(json.dumps(exercise(Path(path), verify_paste=not arguments.input_only), ensure_ascii=False))
        except (AppError, RuntimeError, AssertionError) as exc:
            parser.exit(2, f"Foreground clipboard test stopped: {exc}\n")
    else:
        parser.error("Use --run with a coordinated foreground slot and an empty clipboard.")


if __name__ == "__main__":
    main()
