"""Receive real Shell_NotifyIcon IPC on a private, unswitched test desktop."""

import ctypes as c
import ctypes.wintypes as w
import queue
import struct
import threading
from dataclasses import dataclass

from gaocaozuo.native_win import kernel, user


_PROCEDURE = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)


class _WindowClass(c.Structure):
    _fields_ = [
        ("style", w.UINT), ("procedure", _PROCEDURE), ("extra", c.c_int), ("window_extra", c.c_int),
        ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
        ("menu", w.LPCWSTR), ("name", w.LPCWSTR),
    ]


class _CopyData(c.Structure):
    _fields_ = [("tag", c.c_size_t), ("size", w.DWORD), ("data", w.LPVOID)]


@dataclass(frozen=True)
class ShellOperation:
    operation: int
    hwnd: int
    icon_id: int
    callback: int
    icon: int
    tooltip: str


def _desktop_name(desktop):
    name = c.create_unicode_buffer(128)
    size = w.DWORD()
    query = user("GetUserObjectInformationW", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
    if not query(desktop, 2, name, c.sizeof(name), c.byref(size)):
        raise c.WinError(c.get_last_error())
    return name.value.casefold()


def bind_desktop(desktop):
    """Move only this test thread. The real input desktop is never switched."""
    active = user("OpenInputDesktop", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)(0, False, 1)
    try:
        name = _desktop_name(desktop)
        if name == "default" or (active and _desktop_name(active) == name):
            raise RuntimeError("A shell fixture must never run on the input desktop.")
        if not user("SetThreadDesktop", w.BOOL, w.HANDLE)(desktop):
            raise c.WinError(c.get_last_error())
    finally:
        if active:
            user("CloseDesktop", w.BOOL, w.HANDLE)(active)


def post(hwnd, message, first=0, second=0):
    if not user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, message, first, second):
        raise c.WinError(c.get_last_error())


class ShellTrayFixture:
    def __init__(self, desktop):
        self._desktop = desktop
        self._lock = threading.Lock()
        self._started = queue.Queue()
        self._operations = []
        self._icons = {}
        self._thread = threading.Thread(target=self._loop, name="isolated-shell-tray-fixture", daemon=True)
        self.hwnd = None

    @property
    def operations(self):
        with self._lock:
            return tuple(self._operations)

    @property
    def icons(self):
        with self._lock:
            return tuple(self._icons.values())

    def __enter__(self):
        self._thread.start()
        self.hwnd = self._started.get(timeout=4)
        if isinstance(self.hwnd, Exception):
            raise self.hwnd
        return self

    def __exit__(self, *_):
        post(self.hwnd, 0x0010)  # WM_CLOSE
        self._thread.join(timeout=4)
        if self._thread.is_alive():
            raise RuntimeError("The private taskbar receiver did not exit.")

    def taskbar_created(self, *, clear_icons=True):
        with self._lock:
            windows = {record.hwnd for record in self._icons.values()}
            if clear_icons:
                self._icons.clear()
        message = user("RegisterWindowMessageW", w.UINT, w.LPCWSTR)("TaskbarCreated")
        for hwnd in windows:
            post(hwnd, message)

    def _operation(self, param):
        copy = c.cast(param, c.POINTER(_CopyData)).contents
        if copy.tag != 1 or not copy.data or copy.size < 32:
            return 0
        data = c.string_at(copy.data, copy.size)
        # x64 Shell32 uses the serialized 32-bit HWND/HICON form for this IPC.
        magic, action, _size, hwnd, icon_id, _flags, callback, icon = struct.unpack_from("<8I", data)
        if magic != 0x34753423:
            return 0
        tip = data[32:288].decode("utf-16-le", errors="replace").split("\0", 1)[0]
        record = ShellOperation(action, hwnd, icon_id, callback, icon, tip)
        key = hwnd, icon_id
        with self._lock:
            self._operations.append(record)
            exists = key in self._icons
            if (action == 0 and not exists) or (action == 1 and exists):
                self._icons[key] = record
                return 1
            if action == 2 and exists:
                del self._icons[key]
                return 1
            return int(action in {3, 4} and exists)

    def _loop(self):
        try:
            self._run()
        except Exception as exc:
            self._started.put(exc)

    def _run(self):
        bind_desktop(self._desktop)
        instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
        default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

        @_PROCEDURE
        def receive(hwnd, message, first, second):
            if message == 0x004A:  # WM_COPYDATA
                return self._operation(second)
            if message == 0x0010:  # WM_CLOSE
                user("PostQuitMessage", None, c.c_int)(0)
                return 0
            return default(hwnd, message, first, second)

        class_name = "Shell_TrayWnd"
        window_class = _WindowClass(0, receive, 0, 0, instance, None, None, None, None, class_name)
        if not user("RegisterClassW", w.ATOM, c.POINTER(_WindowClass))(c.byref(window_class)):
            raise c.WinError(c.get_last_error())
        hwnd = None
        try:
            create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                          c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            hwnd = create(0, class_name, "Private notification-area fixture", 0, 0, 0, 0, 0, None, None, instance, None)
            if not hwnd:
                raise c.WinError(c.get_last_error())
            self._started.put(hwnd)
            msg = w.MSG()
            get = user("GetMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)
            dispatch = user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
            while get(c.byref(msg), None, 0, 0) > 0:
                dispatch(c.byref(msg))
        finally:
            if hwnd:
                user("DestroyWindow", w.BOOL, w.HWND)(hwnd)
            user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(class_name, instance)
