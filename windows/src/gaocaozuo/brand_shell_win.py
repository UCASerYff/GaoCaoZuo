"""Publish the app identity and correctly sized icons on the owned Chromium window."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import subprocess
import sys
import time
from contextlib import contextmanager
from uuid import UUID

from gaocaozuo.native_win import bind, user
from gaocaozuo.version import APP_NAME


# Match the AppUserModelID on the installer's Start menu shortcut.
APP_USER_MODEL_ID = "GaoSeries.GaoCaoZuo.Windows"
_PROPERTY_FORMAT = UUID("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3")
_IID_PROPERTY_STORE = (c.c_ubyte * 16).from_buffer_copy(UUID("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99").bytes_le)
_VT_LPWSTR = 31


class _PropertyKey(c.Structure):
    _fields_ = [("format", c.c_ubyte * 16), ("id", w.DWORD)]

    def __init__(self, prop_id):
        super().__init__((c.c_ubyte * 16).from_buffer_copy(_PROPERTY_FORMAT.bytes_le), prop_id)


class _PropertyVariant(c.Structure):
    class _Value(c.Union):
        _fields_ = [("text", c.c_void_p), ("storage", c.c_void_p * 2)]

    _fields_ = [("type", w.USHORT), ("reserved", w.USHORT * 3), ("value", _Value)]


def _store_method(store, slot, result, *args):
    table = c.cast(store, c.POINTER(c.POINTER(c.c_void_p))).contents
    return c.WINFUNCTYPE(result, c.c_void_p, *args)(table[slot])


@contextmanager
def _window_store(hwnd):
    initialize = bind("ole32", "CoInitializeEx", c.c_long, c.c_void_p, w.DWORD)
    status = initialize(None, 2)  # COINIT_APARTMENTTHREADED
    if status < 0 and (status & 0xFFFFFFFF) != 0x80010106:  # The thread may already use an MTA.
        yield None
        return
    pointer = c.c_void_p()
    try:
        get_store = bind("shell32", "SHGetPropertyStoreForWindow", c.c_long, w.HWND, c.c_void_p, c.POINTER(c.c_void_p))
        result = get_store(hwnd, c.byref(_IID_PROPERTY_STORE), c.byref(pointer))
        if result < 0 or not pointer:
            yield None
        else:
            try:
                yield pointer
            finally:
                _store_method(pointer, 2, w.ULONG)(pointer)  # IUnknown::Release
    finally:
        if status >= 0:
            bind("ole32", "CoUninitialize", None)()


def _set_window_properties(hwnd, values):
    with _window_store(hwnd) as store:
        if store is None:
            return
        set_value = _store_method(store, 6, c.c_long, c.POINTER(_PropertyKey), c.POINTER(_PropertyVariant))
        for prop_id, text in values:
            variant = _PropertyVariant()
            if text is not None:
                buffer = c.create_unicode_buffer(text)
                variant.type = _VT_LPWSTR
                # SetValue copies the input. This buffer remains ours throughout the call.
                variant.value.text = c.cast(buffer, c.c_void_p).value
            set_value(store, c.byref(_PropertyKey(prop_id)), c.byref(variant))


class WorkbenchBrand:
    def __init__(self):
        self._window = None
        self._dpi = 0
        self._recheck_at = None
        self._icons = {}
        self._properties = []
        if getattr(sys, "frozen", False):
            self._properties.extend([
                (2, subprocess.list2cmdline([sys.executable])),  # RelaunchCommand
                (3, f"{sys.executable},-1"),  # PyInstaller's RT_GROUP_ICON resource ID.
                (4, APP_NAME),  # RelaunchDisplayNameResource
            ])
        self._properties.append((5, APP_USER_MODEL_ID))  # ID triggers a taskbar refresh.

    def schedule_recheck(self):
        self._recheck_at = max(self._recheck_at or 0, time.monotonic() + 0.3)

    @staticmethod
    def _is_same_owner(hwnd, pid):
        current = w.DWORD()
        query = user("GetWindowThreadProcessId", w.DWORD, w.HWND, w.LPDWORD)
        return query(hwnd, c.byref(current)) and current.value == pid

    def update(self, hwnd, pid):
        from gaocaozuo.brand_icons import icon_metrics, load_native_icon

        identity = hwnd, pid
        dpi = user("GetDpiForWindow", w.UINT, w.HWND)(hwnd) or 96
        now = time.monotonic()
        # Chromium can replace a native icon after load, activation or a DPI change.
        # Reapply once at each transition using the existing workbench lifecycle check.
        new_window = identity != self._window
        dpi_changed = dpi != self._dpi
        recheck = self._recheck_at is not None and now >= self._recheck_at
        if not (new_window or dpi_changed or recheck):
            return
        if not self._is_same_owner(hwnd, pid):
            return
        self._window, self._dpi = identity, dpi
        if new_window:
            self._recheck_at = now + 1.0
        elif dpi_changed:
            self.schedule_recheck()
        elif recheck:
            self._recheck_at = None

        if new_window or recheck:
            _set_window_properties(hwnd, self._properties)
        send = user("SendMessageTimeoutW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
                    w.UINT, w.UINT, c.POINTER(c.c_size_t))
        for small, kind in ((True, 0), (False, 1)):
            size = icon_metrics(dpi, small=small)
            icon = self._icons.get(size)
            if not icon:
                icon = load_native_icon(*size)
                if not icon:
                    continue
                self._icons[size] = icon
            # Never destroy Chromium's old icons. The ones we assign stay live until the job closes.
            send(hwnd, 0x0080, kind, icon, 0x3, 80, c.byref(c.c_size_t()))  # WM_SETICON

    def unbind(self, hwnd, pid):
        if self._window == (hwnd, pid) and self._is_same_owner(hwnd, pid):
            _set_window_properties(hwnd, [(prop_id, None) for prop_id, _ in reversed(self._properties)])

    def close(self):
        destroy = user("DestroyIcon", w.BOOL, w.HICON)
        for icon in self._icons.values():
            destroy(icon)
        self._icons.clear()
