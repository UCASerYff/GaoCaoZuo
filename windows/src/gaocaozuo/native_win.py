"""Typed Win32 bindings used by the desktop runtime."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
from functools import lru_cache
from math import ceil


@lru_cache(maxsize=None)
def bind(dll, name, result, *args):
    function = getattr(c.WinDLL(dll, use_last_error=True), name)
    function.argtypes = args
    function.restype = result
    return function


def user(name, result, *args):
    return bind("user32", name, result, *args)


def kernel(name, result, *args):
    return bind("kernel32", name, result, *args)


def wait_for_messages(seconds: float | None = None) -> None:
    """Sleep until this thread receives native input or an actual deadline."""
    wait = user("MsgWaitForMultipleObjectsEx", w.DWORD, w.DWORD, c.POINTER(w.HANDLE), w.DWORD, w.DWORD, w.DWORD)
    timeout = 0xFFFFFFFF if seconds is None else min(0xFFFFFFFE, max(0, ceil(seconds * 1000)))
    if wait(0, None, timeout, 0x04FF, 0x0004) == 0xFFFFFFFF:  # QS_ALLINPUT, MWMO_INPUTAVAILABLE
        raise c.WinError(c.get_last_error())


def is_input_desktop() -> bool:
    """Only operate on the caller's ordinary interactive desktop."""
    open_input = user("OpenInputDesktop", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
    desktop = open_input(0, False, 0x0001)  # DESKTOP_READOBJECTS
    if not desktop:
        return False
    try:
        get_info = user("GetUserObjectInformationW", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
        name = c.create_unicode_buffer(128)
        needed = w.DWORD()
        if not get_info(desktop, 2, name, c.sizeof(name), c.byref(needed)) or name.value.casefold() != "default":
            return False
        thread_id = kernel("GetCurrentThreadId", w.DWORD)()
        current = user("GetThreadDesktop", w.HANDLE, w.DWORD)(thread_id)
        return bool(current and get_info(current, 2, name, c.sizeof(name), c.byref(needed)) and name.value.casefold() == "default")
    finally:
        user("CloseDesktop", w.BOOL, w.HANDLE)(desktop)


def is_session_active() -> bool:
    query = bind("wtsapi32", "WTSQuerySessionInformationW", w.BOOL, w.HANDLE, w.DWORD, c.c_int,
                 c.POINTER(w.LPVOID), w.LPDWORD)
    value, size = w.LPVOID(), w.DWORD()
    if not query(None, 0xFFFFFFFF, 8, c.byref(value), c.byref(size)):  # current session, WTSConnectState
        return False
    try:
        return value.value is not None and size.value >= c.sizeof(c.c_int) and c.cast(value, c.POINTER(c.c_int)).contents.value == 0
    finally:
        bind("wtsapi32", "WTSFreeMemory", None, w.LPVOID)(value)
