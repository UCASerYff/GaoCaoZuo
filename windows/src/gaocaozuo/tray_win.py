"""Native Windows notification icon for opening and quitting the workbench."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
import sys
import time
from threading import Event, Thread, current_thread

from gaocaozuo.native_win import bind, kernel, user


class _NotifyIcon(c.Structure):
    _fields_ = [
        ("size", w.DWORD), ("window", w.HWND), ("identifier", w.UINT), ("flags", w.UINT),
        ("message", w.UINT), ("icon", w.HICON), ("tip", w.WCHAR * 128), ("state", w.DWORD),
        ("state_mask", w.DWORD), ("info", w.WCHAR * 256), ("version", w.UINT),
        ("info_title", w.WCHAR * 64), ("info_flags", w.DWORD), ("guid", c.c_ubyte * 16),
        ("balloon", w.HICON),
    ]


_TRAY_MESSAGE = 0x8001


class WindowsTray:
    def __init__(self, show, quit):
        self.show = show
        self.quit = quit
        self._stop = Event()
        self._enabled = False
        self._thread = None
        self._window = None
        self.registered = False
        self.ready = Event()

    def configure(self, enabled: bool) -> None:
        self._enabled = bool(enabled)

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = Thread(target=self._loop, name="gaocaozuo-windows-tray", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._window:
            user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(self._window, 0x001F, 0, 0)  # WM_CANCELMODE
        if self._thread is not None and current_thread() is not self._thread:
            self._thread.join(timeout=2)

    def _menu(self, hwnd, anchor) -> int:
        menu = user("CreatePopupMenu", w.HMENU)()
        if not menu:
            return 0
        try:
            append = user("AppendMenuW", w.BOOL, w.HMENU, w.UINT, c.c_size_t, w.LPCWSTR)
            if not (append(menu, 0, 1, "打开搞操作") and append(menu, 0, 2, "退出搞操作")):
                return 0
            point = w.POINT(c.c_short(anchor & 0xFFFF).value, c.c_short((anchor >> 16) & 0xFFFF).value)
            if not anchor or (point.x, point.y) == (-1, -1):
                user("GetCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(point))
            user("SetForegroundWindow", w.BOOL, w.HWND)(hwnd)
            track = user("TrackPopupMenuEx", w.UINT, w.HMENU, w.UINT, c.c_int, c.c_int, w.HWND, w.LPVOID)
            command = track(menu, 0x0100 | 0x0080 | 0x0002, point.x, point.y, hwnd, None)
            user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, 0, 0, 0)
            return command
        finally:
            user("DestroyMenu", w.BOOL, w.HMENU)(menu)

    def _loop(self) -> None:
        procedure = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

        class WindowClass(c.Structure):
            _fields_ = [("style", w.UINT), ("callback", procedure), ("class_extra", c.c_int), ("window_extra", c.c_int),
                        ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                        ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]

        instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
        class_name = f"GaoCaoZuo.Tray.{os.getpid()}.{id(self)}"
        taskbar = user("RegisterWindowMessageW", w.UINT, w.LPCWSTR)("TaskbarCreated")
        default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        notify = bind("shell32", "Shell_NotifyIconW", w.BOOL, w.DWORD, c.POINTER(_NotifyIcon))
        data = _NotifyIcon()
        next_register = 0.0
        has_v4 = False

        @procedure
        def callback(hwnd, message, first, second):
            nonlocal next_register
            if message == taskbar:
                self.registered = False
                next_register = 0.0
                return 0
            if message == _TRAY_MESSAGE:
                event = second & 0xFFFF
                try:
                    if (has_v4 and event in {0x0400, 0x0401}) or (not has_v4 and event == 0x0202):
                        self.show()
                    elif (has_v4 and event == 0x007B) or (not has_v4 and event == 0x0205):
                        command = self._menu(hwnd, first if has_v4 else 0)
                        if command == 1:
                            self.show()
                        elif command == 2:
                            self.quit()
                        else:
                            notify(3, c.byref(data))  # NIM_SETFOCUS when dismissed without an action
                except Exception:
                    pass
                return 0
            return default(hwnd, message, first, second)

        descriptor = WindowClass(0, callback, 0, 0, instance, None, None, None, None, class_name)
        atom = user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))(c.byref(descriptor))
        if not atom:
            self.ready.set()
            return
        icon = w.HICON()
        owns_icon = False
        try:
            create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                          c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            self._window = create(0, class_name, "搞操作 · 通知区域", 0, 0, 0, 0, 0, None, None, instance, None)
            self.ready.set()
            if not self._window:
                return
            extract = bind("shell32", "ExtractIconExW", w.UINT, w.LPCWSTR, c.c_int, c.POINTER(w.HICON), c.POINTER(w.HICON), w.UINT)
            if getattr(sys, "frozen", False):
                owns_icon = extract(sys.executable, 0, None, c.byref(icon), 1) == 1 and bool(icon)
            if not owns_icon:
                icon = user("LoadIconW", w.HICON, w.HINSTANCE, c.c_void_p)(None, 32512)
            data.size, data.window, data.identifier = c.sizeof(data), self._window, 1
            data.flags, data.message, data.icon, data.tip, data.version = 0x87, _TRAY_MESSAGE, icon, "搞操作", 4
            msg = w.MSG()
            peek = user("PeekMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT)
            dispatch = user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
            while not self._stop.is_set():
                while peek(c.byref(msg), None, 0, 0, 1):
                    dispatch(c.byref(msg))
                if self._enabled and not self.registered and time.monotonic() >= next_register:
                    self.registered = bool(notify(0, c.byref(data)))
                    has_v4 = self.registered and bool(notify(4, c.byref(data)))
                    next_register = time.monotonic() + 2
                elif not self._enabled and self.registered:
                    notify(2, c.byref(data))
                    self.registered = False
                    next_register = 0.0
                self._stop.wait(0.04)
        finally:
            if self.registered:
                notify(2, c.byref(data))
                self.registered = False
            if self._window:
                user("DestroyWindow", w.BOOL, w.HWND)(self._window)
                self._window = None
            if owns_icon:
                user("DestroyIcon", w.BOOL, w.HICON)(icon)
            user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(class_name, instance)
