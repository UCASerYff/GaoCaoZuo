"""Use a fresh noninteractive Windows station to test real clipboard and EDIT consumption."""

from __future__ import annotations

import argparse
import ctypes as c
import ctypes.wintypes as w
import json
import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


PAYLOAD = "GaoCaoZuo 合成普通粘贴 Ω"


def api(dll, name, result, *arguments):
    result_fn = getattr(c.WinDLL(dll, use_last_error=True), name)
    result_fn.restype, result_fn.argtypes = result, arguments
    return result_fn


def user(name, result, *arguments):
    return api("user32", name, result, *arguments)


def kernel(name, result, *arguments):
    return api("kernel32", name, result, *arguments)


def checked(value, operation):
    if not value:
        raise RuntimeError(f"{operation} returned Win32 {c.get_last_error()}.")
    return value


class StartupInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                ("x", w.DWORD), ("y", w.DWORD), ("width", w.DWORD), ("height", w.DWORD), ("columns", w.DWORD),
                ("rows", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD), ("show", w.WORD),
                ("reserved_bytes", w.WORD), ("reserved_data", w.LPVOID), ("stdin", w.HANDLE), ("stdout", w.HANDLE),
                ("stderr", w.HANDLE)]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class StationFlags(c.Structure):
    _fields_ = [("inherit", w.BOOL), ("reserved", w.BOOL), ("flags", w.DWORD)]


def attach_new_station():
    create_station = user("CreateWindowStationW", w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID)
    # CWF_CREATE_ONLY refuses any existing station for this logon. No clipboard APIs run before verification.
    station = checked(create_station(None, 1, 0x31F, None), "CreateWindowStationW(CWF_CREATE_ONLY)")
    inspect = user("GetUserObjectInformationW", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
    flags, name, needed = StationFlags(), c.create_unicode_buffer(128), w.DWORD()
    checked(inspect(station, 1, c.byref(flags), c.sizeof(flags), c.byref(needed)), "GetUserObjectInformationW(UOI_FLAGS)")
    checked(inspect(station, 2, name, c.sizeof(name), c.byref(needed)), "GetUserObjectInformationW(UOI_NAME)")
    if not name.value or name.value.casefold() == "winsta0" or flags.flags & 1:
        raise RuntimeError("The fixture was refused because the station is interactive.")
    checked(user("SetProcessWindowStation", w.BOOL, w.HANDLE)(station), "SetProcessWindowStation")
    create_desktop = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)
    desktop = checked(create_desktop("GaoCaoZuoClipboardFixture", None, None, 0, 0x1FF, None), "CreateDesktopW")
    checked(user("SetThreadDesktop", w.BOOL, w.HANDLE)(desktop), "SetThreadDesktop")
    if user("GetProcessWindowStation", w.HANDLE)() != station:
        raise RuntimeError("The process station was not the new noninteractive station.")
    current_thread = kernel("GetCurrentThreadId", w.DWORD)()
    if user("GetThreadDesktop", w.HANDLE, w.DWORD)(current_thread) != desktop:
        raise RuntimeError("The fixture desktop was not attached.")


def exercise(directory: Path):
    attach_new_station()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
    from gaocaozuo.app import App
    from gaocaozuo.errors import AppError
    from gaocaozuo.native_win import is_input_desktop
    from gaocaozuo.system import FakeSystem

    assert not is_input_desktop(), "The private station must be isolated from global input."
    app = App(directory / "app-data", interactive=True, system=FakeSystem())
    clipboard = app.native_clipboard
    assert clipboard.snapshot()[1] == {}, "The newly created station clipboard was not empty."
    create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int, c.c_int,
                  c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
    top = checked(create(0, "STATIC", "GaoCaoZuo synthetic native paste", 0x00CF0000, 0, 0, 420, 140, None, None, None, None),
                  "CreateWindowExW(top)")
    try:
        edit = checked(create(0, "EDIT", "", 0x50010080, 12, 12, 350, 28, top, None, None, None), "CreateWindowExW(EDIT)")
        user("ShowWindow", w.BOOL, w.HWND, c.c_int)(top, 5)
        user("SetActiveWindow", w.HWND, w.HWND)(top)
        user("SetFocus", w.HWND, w.HWND)(edit)
        get_focus = user("GetFocus", w.HWND)
        assert get_focus() == edit and clipboard.focus_details(top) == (edit, False, True)
        send_message = user("SendMessageW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        get_text = user("GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
        text = c.create_unicode_buffer(256)
        target = SimpleNamespace(hwnd=top)

        def require_target(identity):
            assert identity is target and get_focus() == edit and clipboard.focus_details(top) == (edit, False, True)

        def target_for(target_id):
            assert target_id == "synthetic"
            return target

        app.clipboard.desktop = SimpleNamespace(target=target_for, focus_target=require_target, require_foreground=require_target)

        def deliver(keys, expected_window):
            # Only the dispatch is substituted. The stock EDIT handler reads the real Win32 clipboard.
            assert keys == (0x11, ord("V")) and expected_window == top
            require_target(target)
            send_message(edit, 0x0302, 0, 0)  # WM_PASTE
            return True

        original = clipboard.plain_formats("合成原始剪贴板")
        original[clipboard.named["Rich Text Format"]] = b"{\\rtf1 original synthetic formatting}\0"
        clipboard.replace(original)
        original_snapshot = clipboard.snapshot()[1]
        with patch("gaocaozuo.platform_win.send_keys", deliver):
            reply = app.perform("clipboard.pasteplain", {"text": PAYLOAD, "targetID": "synthetic", "sendEnter": True})
            assert reply["phase"] == "awaitingUser" and reply["eventWasSubmitted"] and not reply["automaticEnter"]
            assert get_text(edit, text, len(text)) == len(PAYLOAD) and text.value == PAYLOAD
            confirmation = app.clipboard.confirm()
            assert confirmation["restored"] and not confirmation["enterSubmitted"]
            assert clipboard.snapshot()[1] == original_snapshot

            app.perform("clipboard.pasteplain", {"text": PAYLOAD, "targetID": "synthetic"})
            assert app.clipboard.cancel()["restored"] and clipboard.snapshot()[1] == original_snapshot

            app.perform("clipboard.pasteplain", {"text": PAYLOAD, "targetID": "synthetic"})
            replacement = clipboard.plain_formats("合成并发更新")
            clipboard.replace(replacement)
            try:
                app.clipboard.confirm()
            except AppError as error:
                assert error.code == "changed"
            else:
                raise AssertionError("The pending transaction replaced the concurrent clipboard content.")
            assert clipboard.text() == "合成并发更新" and app.clipboard.transaction is None
        return {"separateClipboard": True, "nativeEditConsumed": True, "originalFormatsRestored": True, "cancelRestored": True,
                "concurrentContentPreserved": True, "automaticEnter": False, "dispatch": "targeted WM_PASTE"}
    finally:
        user("DestroyWindow", w.BOOL, w.HWND)(top)


def run_child():
    interpreter = Path(sys.executable).with_name("pythonw.exe")
    if not interpreter.is_file():
        raise RuntimeError("A windowless Python interpreter is required.")
    with tempfile.TemporaryDirectory(prefix="GaoCaoZuo-isolated-clipboard-") as name:
        directory = Path(name)
        startup, process = StartupInfo(size=c.sizeof(StartupInfo)), ProcessInfo()
        command = c.create_unicode_buffer(subprocess.list2cmdline(
            [str(interpreter), "-I", str(Path(__file__).resolve()), "--isolated-child", str(directory)]))
        launch = api("advapi32", "CreateProcessWithLogonW", w.BOOL, w.LPCWSTR, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                     w.LPCWSTR, w.LPWSTR, w.DWORD, w.LPVOID, w.LPCWSTR, c.POINTER(StartupInfo), c.POINTER(ProcessInfo))
        # NETCREDENTIALS_ONLY provides a separate logon ID under the same local user.
        # The synthetic outbound values are never used for authentication or network connections.
        checked(launch("GaoFixture_" + uuid.uuid4().hex, "fixture.invalid", uuid.uuid4().hex, 2, str(interpreter),
                       command, subprocess.CREATE_NO_WINDOW, None, name, c.byref(startup), c.byref(process)),
                "CreateProcessWithLogonW(LOGON_NETCREDENTIALS_ONLY)")
        wait = kernel("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
        close = kernel("CloseHandle", w.BOOL, w.HANDLE)
        try:
            if wait(process.process, 15000) != 0:
                kernel("TerminateProcess", w.BOOL, w.HANDLE, w.UINT)(process.process, 2)
                wait(process.process, 3000)
                raise RuntimeError("The private station fixture did not finish.")
            result_path = directory / "result.json"
            if not result_path.is_file():
                code = w.DWORD()
                kernel("GetExitCodeProcess", w.BOOL, w.HANDLE, w.LPDWORD)(process.process, c.byref(code))
                raise RuntimeError(f"The private station fixture produced no result (exit {code.value}).")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            if "error" in result:
                raise RuntimeError(f"{result['error']} (fixture line {result['line']})")
            print(json.dumps(result, ensure_ascii=False))
        finally:
            close(process.thread)
            close(process.process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--isolated-child", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required.")
    if args.isolated_child:
        try:
            result = exercise(args.isolated_child)
        except Exception as error:
            import traceback

            result = {"error": "".join(traceback.format_exception_only(type(error), error)).rstrip(),
                      "line": traceback.extract_tb(error.__traceback__)[-1].lineno}
        (args.isolated_child / "result.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    elif args.run:
        run_child()
    else:
        parser.error("Use --run to exercise a new noninteractive window station.")


if __name__ == "__main__":
    main()
