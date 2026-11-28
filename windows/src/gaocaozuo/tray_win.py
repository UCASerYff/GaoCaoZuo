"""Native Windows notification icon for opening and quitting the workbench."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
import time
from threading import Event, Thread, current_thread

from gaocaozuo.brand_icons import icon_metrics, load_native_icon
from gaocaozuo.desktop_win import physical_coordinates
from gaocaozuo.native_win import bind, kernel, user, wait_for_messages
from gaocaozuo.version import APP_NAME


class _NotifyIcon(c.Structure):
    _fields_ = [
        ("size", w.DWORD), ("window", w.HWND), ("identifier", w.UINT), ("flags", w.UINT),
        ("message", w.UINT), ("icon", w.HICON), ("tip", w.WCHAR * 128), ("state", w.DWORD),
        ("state_mask", w.DWORD), ("info", w.WCHAR * 256), ("version", w.UINT),
        ("info_title", w.WCHAR * 64), ("info_flags", w.DWORD), ("guid", c.c_ubyte * 16),
        ("balloon", w.HICON),
    ]


_TRAY_MESSAGE = 0x8001
_ICON_ID = 1
_ADD, _MODIFY, _DELETE, _SETFOCUS, _SETVERSION = range(5)
_DPI_CHANGED = 0x02E0


def _notification_dpi(hwnd, changed_dpi=0) -> int:
    try:
        get_dpi = user("GetDpiForWindow", w.UINT, w.HWND)
        taskbar = user("FindWindowW", w.HWND, w.LPCWSTR, w.LPCWSTR)("Shell_TrayWnd", None)
        if taskbar:
            context = user("GetWindowDpiAwarenessContext", w.HANDLE, w.HWND)(taskbar)
            awareness = user("GetAwarenessFromDpiAwarenessContext", c.c_int, w.HANDLE)(context)
            if awareness == 2 and (dpi := get_dpi(taskbar)):  # DPI_AWARENESS_PER_MONITOR_AWARE
                return dpi
        return changed_dpi or get_dpi(hwnd) or 96
    except AttributeError:
        return changed_dpi or 96


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
        self.taskbar_created = Event()

    def configure(self, enabled: bool) -> None:
        self._enabled = bool(enabled)
        if self._window:
            user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(self._window, 0, 0, 0)

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
            if not (append(menu, 0, 1, f"打开 {APP_NAME}") and append(menu, 0, 2, "退出")):
                return 0
            user("SetMenuDefaultItem", w.BOOL, w.HMENU, w.UINT, w.UINT)(menu, 1, 0)
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
        with physical_coordinates():
            self._run()

    def _run(self) -> None:
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
        announced = False
        pending_dpi = None

        @procedure
        def callback(hwnd, message, first, second):
            nonlocal next_register, has_v4, pending_dpi
            if taskbar and message == taskbar:
                self.taskbar_created.set()
                self.registered = False
                has_v4 = False
                next_register = 0.0
                pending_dpi = 0
                return 0
            if message == _DPI_CHANGED:
                pending_dpi = first & 0xFFFF
                next_register = 0.0
                return 0
            if message == _TRAY_MESSAGE:
                icon_id = (second >> 16) & 0xFFFF if has_v4 else first
                if icon_id != _ICON_ID or not self.registered or not self._enabled or self._stop.is_set():
                    return 0
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
                            notify(_SETFOCUS, c.byref(data))
                except Exception:
                    pass
                return 0
            return default(hwnd, message, first, second)

        descriptor = WindowClass(0, callback, 0, 0, instance, None, None, None, None, class_name)
        atom = user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))(c.byref(descriptor))
        if not atom:
            self.ready.set()
            return
        icon = None
        icon_size = None
        destroy_icon = user("DestroyIcon", w.BOOL, w.HICON)
        try:
            create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                          c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            self._window = create(0, class_name, "搞操作 · 通知区域", 0, 0, 0, 0, 0, None, None, instance, None)
            self.ready.set()
            if not self._window:
                return
            data.size, data.window, data.identifier = c.sizeof(data), self._window, _ICON_ID
            data.flags, data.message, data.tip, data.version = 0x87, _TRAY_MESSAGE, APP_NAME, 4
            msg = w.MSG()
            peek = user("PeekMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT)
            dispatch = user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
            while not self._stop.is_set():
                while not self._stop.is_set() and peek(c.byref(msg), None, 0, 0, 1):
                    dispatch(c.byref(msg))
                if self._stop.is_set():
                    break
                if self._enabled and (not self.registered or pending_dpi is not None) and time.monotonic() >= next_register:
                    changed_dpi, pending_dpi = pending_dpi, None
                    dpi = _notification_dpi(self._window, changed_dpi or 0)
                    size = icon_metrics(dpi, small=True)
                    replacement = load_native_icon(*size) if icon_size != size else None
                    if not (replacement or icon):
                        icon = user("LoadIconW", w.HICON, w.HINSTANCE, c.c_void_p)(None, 32512)
                    data.icon = replacement or icon
                    if not self.registered or not notify(_MODIFY, c.byref(data)):
                        # Explorer may have removed the icon, or kept it during a DPI change.
                        added = notify(_ADD, c.byref(data)) or notify(_MODIFY, c.byref(data))
                        has_v4 = bool(added and notify(_SETVERSION, c.byref(data)))
                        self.registered = bool(added)
                        announced = announced or bool(added)
                    if replacement:
                        if self.registered:
                            if icon_size is not None:
                                destroy_icon(icon)
                            icon, icon_size = replacement, size
                        else:
                            destroy_icon(replacement)
                        data.icon = icon
                    next_register = 0.0 if pending_dpi is not None else time.monotonic() + 2
                elif not self._enabled and announced:
                    notify(_DELETE, c.byref(data))
                    announced = False
                    self.registered = False
                    has_v4 = False
                    next_register = 0.0
                # An installed icon has nothing to poll. A shell event dispatched
                # during a synchronous notification call can still require a refresh.
                pending = self._enabled and (not self.registered or pending_dpi is not None)
                retry = next_register - time.monotonic() if pending else None
                wait_for_messages(retry)
        finally:
            if announced:
                notify(_DELETE, c.byref(data))
                self.registered = False
            if self._window:
                user("DestroyWindow", w.BOOL, w.HWND)(self._window)
                self._window = None
            if icon_size is not None:
                destroy_icon(icon)
            user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(class_name, instance)
