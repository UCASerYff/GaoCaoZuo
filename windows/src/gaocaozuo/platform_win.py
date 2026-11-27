"""只在 Windows 上调用系统接口。其他系统返回明确失败。"""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
from threading import RLock

from gaocaozuo.errors import AppError
from gaocaozuo.native_win import bind, is_input_desktop, kernel, user


def _windll():
    if os.name != "nt":
        raise AppError("当前不是 Windows。", "unavailable")
    import ctypes

    return ctypes


def lock_workstation() -> bool:
    _windll()
    return bool(is_input_desktop() and user("LockWorkStation", w.BOOL)())


def start_screensaver() -> bool:
    _windll()
    post = user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    return bool(is_input_desktop() and post(0xFFFF, 0x0112, 0xF140, 0))


class _LocalIdentifier(c.Structure):
    _fields_ = [("low", w.DWORD), ("high", w.LONG)]


class _TokenPrivilege(c.Structure):
    _fields_ = [("count", w.DWORD), ("identifier", _LocalIdentifier), ("attributes", w.DWORD)]


_suspend_lock = RLock()


def suspend() -> bool:
    _windll()
    if not is_input_desktop():
        return False
    with _suspend_lock:
        process = kernel("GetCurrentProcess", w.HANDLE)()
        token = w.HANDLE()
        open_token = bind("advapi32", "OpenProcessToken", w.BOOL, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE))
        if not open_token(process, 0x0008 | 0x0020, c.byref(token)):  # TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES
            return False
        try:
            privilege = _TokenPrivilege(1, _LocalIdentifier(), 2)  # SE_PRIVILEGE_ENABLED
            lookup = bind("advapi32", "LookupPrivilegeValueW", w.BOOL, w.LPCWSTR, w.LPCWSTR, c.POINTER(_LocalIdentifier))
            if not lookup(None, "SeShutdownPrivilege", c.byref(privilege.identifier)):
                return False
            previous, length = _TokenPrivilege(), w.DWORD()
            entry = c.POINTER(_TokenPrivilege)
            adjust = bind("advapi32", "AdjustTokenPrivileges", w.BOOL, w.HANDLE, w.BOOL, entry, w.DWORD, entry, w.LPDWORD)
            c.set_last_error(0)
            if not adjust(token, False, c.byref(privilege), c.sizeof(previous), c.byref(previous), c.byref(length)) or c.get_last_error():
                return False
            try:
                power = bind("powrprof", "SetSuspendState", c.c_ubyte, c.c_ubyte, c.c_ubyte, c.c_ubyte)
                return bool(is_input_desktop() and power(0, 0, 0))
            finally:
                if previous.count:
                    adjust(token, False, c.byref(previous), 0, None, None)
        finally:
            kernel("CloseHandle", w.BOOL, w.HANDLE)(token)


_MEDIA = {
    "volumeUp": 0xAF,
    "volumeDown": 0xAE,
    "mute": 0xAD,
    "nextTrack": 0xB0,
    "previousTrack": 0xB1,
    "playPause": 0xB3,
}

_SHELL_KEYS = {
    "missionControl": (0x5B, 0x09),
    "showDesktop": (0x5B, ord("D")),
    "spaceLeft": (0x5B, 0x11, 0x25),
    "spaceRight": (0x5B, 0x11, 0x27),
    "createDesktop": (0x5B, 0x11, ord("D")),
    "closeDesktop": (0x5B, 0x11, 0x73),
}

_POINTER_INT = c.c_size_t
_EXTRA_INFO = 0x47414F43


class _KeyboardInput(c.Structure):
    _fields_ = [("vk", w.WORD), ("scan", w.WORD), ("flags", w.DWORD), ("time", w.DWORD), ("extra", _POINTER_INT)]


class _MouseInput(c.Structure):
    _fields_ = [("x", w.LONG), ("y", w.LONG), ("data", w.DWORD), ("flags", w.DWORD), ("time", w.DWORD), ("extra", _POINTER_INT)]


class _InputUnion(c.Union):
    _fields_ = [("keyboard", _KeyboardInput), ("mouse", _MouseInput)]


class _Input(c.Structure):
    _fields_ = [("type", w.DWORD), ("data", _InputUnion)]


def send_keys(keys: tuple[int, ...], expected_window: int | None = None) -> bool:
    """Submit a bounded key sequence through normal Windows input checks."""
    _windll()
    get_key = user("GetAsyncKeyState", c.c_short, c.c_int)
    foreground = user("GetForegroundWindow", w.HWND)
    if not is_input_desktop() or not foreground() or (expected_window is not None and foreground() != expected_window):
        return False
    # An existing key press belongs to the user. Never release it on their behalf.
    if any(get_key(key) & 0x8000 for key in {*keys, 0x10, 0x11, 0x12, 0x5B, 0x5C}):
        return False

    def event(key, up=False):
        extended = key in {0x25, 0x26, 0x27, 0x28, 0x5B, 0x5C, *_MEDIA.values()}
        return _Input(1, _InputUnion(keyboard=_KeyboardInput(key, 0, (1 if extended else 0) | (2 if up else 0), 0, _EXTRA_INFO)))

    send = user("SendInput", w.UINT, w.UINT, c.POINTER(_Input), c.c_int)
    events = [event(key) for key in keys] + [event(key, up=True) for key in reversed(keys)]
    if expected_window is not None and foreground() != expected_window:
        return False
    count = send(len(events), (_Input * len(events))(*events), c.sizeof(_Input))
    if count == len(events):
        return True
    pressed = min(count, len(keys))
    released = max(0, count - len(keys))
    pending = [event(key, up=True) for key in reversed(keys[:pressed - released])]
    if pending:
        send(len(pending), (_Input * len(pending))(*pending), c.sizeof(_Input))
    return False


def media_key(name: str) -> bool:
    if name not in _MEDIA:
        raise AppError("这个系统动作在 Windows 上没有对应媒体键。", "unavailable")
    return send_keys((_MEDIA[name],))


class _LastInputInfo(c.Structure):
    _fields_ = [("size", w.UINT), ("tick", w.DWORD)]


def last_input() -> tuple[int, float]:
    """Return the interactive session's last input timestamp and idle duration."""
    info = _LastInputInfo(c.sizeof(_LastInputInfo), 0)
    if not user("GetLastInputInfo", w.BOOL, c.POINTER(_LastInputInfo))(c.byref(info)):
        raise AppError("Windows 未返回本会话的闲置时间。", "unavailable")
    now = kernel("GetTickCount64", c.c_uint64)()
    elapsed = ((now & 0xFFFFFFFF) - info.tick) & 0xFFFFFFFF
    return info.tick, elapsed / 1000 if elapsed < 0x7FFFFFFF else 0.0


class _DetailedReason(c.Structure):
    _fields_ = [("module", w.HMODULE), ("id", w.ULONG), ("count", w.ULONG), ("strings", c.POINTER(w.LPWSTR))]


class _PowerReason(c.Union):
    _fields_ = [("detail", _DetailedReason), ("simple", w.LPWSTR)]


class _ReasonContext(c.Structure):
    _fields_ = [("version", w.ULONG), ("flags", w.DWORD), ("reason", _PowerReason)]


def set_clipboard_text(text: str) -> None:
    _windll()
    from gaocaozuo.clipboard_win import WindowsClipboard

    clipboard = WindowsClipboard()
    clipboard.replace(clipboard.plain_formats(text))


def get_clipboard_text() -> str:
    _windll()
    from gaocaozuo.clipboard_win import WindowsClipboard

    try:
        return WindowsClipboard().text()
    except AppError as exc:
        if exc.code != "missing":
            raise
        return ""


class WindowsSystem:
    def __init__(self):
        self._power_request = None
        self._power_lock = RLock()

    def lock(self) -> bool:
        return lock_workstation()

    def screensaver(self) -> bool:
        return start_screensaver()

    def sleep(self) -> bool:
        return suspend()

    def set_awake(self, enabled: bool) -> bool:
        with self._power_lock:
            close = kernel("CloseHandle", w.BOOL, w.HANDLE)
            if not enabled:
                if self._power_request and not close(self._power_request):
                    return False
                self._power_request = None
                return True
            if self._power_request:
                return True
            reason = _ReasonContext(0, 1, _PowerReason(simple="搞操作 · 保持唤醒"))
            request = kernel("PowerCreateRequest", w.HANDLE, c.POINTER(_ReasonContext))(c.byref(reason))
            if not request or request == c.c_void_p(-1).value:
                return False
            activate = kernel("PowerSetRequest", w.BOOL, w.HANDLE, c.c_int)
            if not activate(request, 0) or not activate(request, 1):  # display and system
                close(request)
                return False
            self._power_request = request
            return True

    def media(self, name: str) -> bool:
        return media_key(name)

    def desktop(self, name: str) -> bool:
        if name not in _SHELL_KEYS:
            raise AppError("Windows 没有对应的桌面快捷键。", "unavailable")
        return send_keys(_SHELL_KEYS[name])

    def close(self) -> None:
        self.set_awake(False)


def capture_screen():
    """Return the RGB tuple requested by the earlier screenshot entry point."""
    _windll()
    from gaocaozuo.capture_win import capture

    with capture("virtual") as image, image.convert("RGB") as rgb:
        return rgb.width, rgb.height, rgb.tobytes()


def list_windows() -> list[dict]:
    _windll()
    from gaocaozuo.desktop_win import WindowsDesktop

    return WindowsDesktop().overview()["windows"]


def move_window(hwnd: int, x: int, y: int, width: int, height: int) -> bool:
    _windll()
    if not is_input_desktop():
        return False
    move = user("SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT)
    return bool(move(hwnd, None, x, y, width, height, 0x4000 | 0x0010 | 0x0004))
