"""Windows workspace inventory and verified operations on external windows."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import hashlib
import os
import secrets
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import PureWindowsPath
from threading import RLock

from gaocaozuo.errors import AppError, LayoutFailure
from gaocaozuo.layout import LayoutTransaction, Rect, is_window_drag, matches, screen_index, snap_target, target_frame
from gaocaozuo.native_win import bind, is_input_desktop, kernel, user


@dataclass(frozen=True)
class WindowIdentity:
    hwnd: int
    pid: int
    thread: int
    creation: int
    class_name: str
    application: str = field(compare=False)


@dataclass(frozen=True)
class Display:
    screen: Rect
    work: Rect
    name: str
    primary: bool

    def public(self) -> dict:
        return {"name": self.name, "primary": self.primary, "frame": self.screen.as_dict(), "workArea": self.work.as_dict()}


class _MonitorInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("screen", w.RECT), ("work", w.RECT), ("flags", w.DWORD), ("name", w.WCHAR * 32)]


def _rect(box: w.RECT) -> Rect:
    return Rect(box.left, box.top, box.right - box.left, box.bottom - box.top)


@contextmanager
def physical_coordinates():
    try:
        awareness = user("SetThreadDpiAwarenessContext", w.HANDLE, w.HANDLE)
    except AttributeError:
        yield
        return
    previous = awareness(c.c_void_p(-4)) or awareness(c.c_void_p(-3))
    try:
        yield
    finally:
        if previous:
            awareness(previous)


@contextmanager
def _window_coordinates(hwnd: int, native: Rect, left: int, top: int, right: int, bottom: int):
    try:
        context = user("GetWindowDpiAwarenessContext", w.HANDLE, w.HWND)(hwnd)
        level = user("GetAwarenessFromDpiAwarenessContext", c.c_int, w.HANDLE)(context)
        set_context = user("SetThreadDpiAwarenessContext", w.HANDLE, w.HANDLE)
    except AttributeError:
        context, level = None, 2
    previous = set_context(context) if context and level in {0, 1} else None
    try:
        # Some legacy windows receive logical coordinates even while the monitor
        # inventory and DWM frame are physical. Derive both axes from the same HWND.
        if previous:
            logical = _native_frame(hwnd)
            ratio_x, ratio_y = logical.w / native.w, logical.h / native.h
            left, right = (round(logical.x + (edge - native.x) * ratio_x) for edge in (left, right))
            top, bottom = (round(logical.y + (edge - native.y) * ratio_y) for edge in (top, bottom))
        yield left, top, right - left, bottom - top
    finally:
        if previous:
            set_context(previous)


def _enumerate_windows() -> list[int]:
    procedure = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    handles = []

    @procedure
    def append(hwnd, _):
        if hwnd:
            handles.append(int(hwnd))
        return True

    if not user("EnumWindows", w.BOOL, procedure, w.LPARAM)(append, 0):
        raise AppError("Windows 未返回当前桌面的窗口列表。", "rejected")
    return handles


def _displays() -> list[Display]:
    procedure = c.WINFUNCTYPE(w.BOOL, w.HANDLE, w.HDC, c.POINTER(w.RECT), w.LPARAM)
    displays = []

    @procedure
    def append(monitor, _dc, _rect_ptr, _param):
        info = _MonitorInfo()
        info.size = c.sizeof(info)
        if user("GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(_MonitorInfo))(monitor, c.byref(info)):
            displays.append(Display(_rect(info.screen), _rect(info.work), info.name, bool(info.flags & 1)))
        return True

    if not user("EnumDisplayMonitors", w.BOOL, w.HDC, c.POINTER(w.RECT), procedure, w.LPARAM)(None, None, append, 0) or not displays:
        raise AppError("没有可用的显示器工作区。", "unavailable")
    return sorted(displays, key=lambda display: (display.screen.x, display.screen.y, display.name))


def _identity(hwnd: int) -> WindowIdentity | None:
    if not hwnd:
        return None
    pid = w.DWORD()
    thread = user("GetWindowThreadProcessId", w.DWORD, w.HWND, w.LPDWORD)(hwnd, c.byref(pid))
    if not thread or not pid.value:
        return None
    class_name = c.create_unicode_buffer(256)
    if not user("GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)(hwnd, class_name, len(class_name)):
        return None
    process = kernel("OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)(0x1000, False, pid.value)
    if not process:
        return None
    try:
        times = [w.FILETIME() for _ in range(4)]
        time_pointer = c.POINTER(w.FILETIME)
        if not kernel("GetProcessTimes", w.BOOL, w.HANDLE, time_pointer, time_pointer, time_pointer, time_pointer)(
            process, *(c.byref(item) for item in times)
        ):
            return None
        creation = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        length = w.DWORD(1024)
        path = c.create_unicode_buffer(length.value)
        query = kernel("QueryFullProcessImageNameW", w.BOOL, w.HANDLE, w.DWORD, w.LPWSTR, w.LPDWORD)
        application = PureWindowsPath(path.value).name if query(process, 0, path, c.byref(length)) else ""
        return WindowIdentity(hwnd, pid.value, thread, creation, class_name.value, application)
    finally:
        kernel("CloseHandle", w.BOOL, w.HANDLE)(process)


def _title(hwnd: int) -> str:
    value = c.create_unicode_buffer(1024)
    user("GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)(hwnd, value, len(value))
    return value.value.strip()


def _foreground() -> int:
    return int(user("GetForegroundWindow", w.HWND)() or 0)


def _window_flag(name: str, hwnd: int) -> bool:
    return bool(user(name, w.BOOL, w.HWND)(hwnd))


def _native_frame(hwnd: int) -> Rect:
    value = w.RECT()
    if not user("GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(value)):
        raise AppError("Windows 未返回窗口位置。", "changed")
    frame = _rect(value)
    if frame.w <= 0 or frame.h <= 0:
        raise AppError("窗口位置或尺寸无效。", "changed")
    return frame


def _dwm_attribute(hwnd: int, attribute: int, target) -> bool:
    query = bind("dwmapi", "DwmGetWindowAttribute", c.c_long, w.HWND, w.DWORD, w.LPVOID, w.DWORD)
    return query(hwnd, attribute, c.byref(target), c.sizeof(target)) == 0


def _frame(hwnd: int) -> Rect:
    visible = w.RECT()
    if not _window_flag("IsIconic", hwnd) and _dwm_attribute(hwnd, 9, visible):  # DWMWA_EXTENDED_FRAME_BOUNDS
        rect = _rect(visible)
        if rect.w > 0 and rect.h > 0:
            return rect
    return _native_frame(hwnd)


def _await(predicate, timeout=0.55) -> bool:
    until = time.monotonic() + timeout
    while True:
        if predicate():
            return True
        if time.monotonic() >= until:
            return False
        time.sleep(0.015)


def _style(hwnd: int, index: int) -> int:
    return user("GetWindowLongW", c.c_long, w.HWND, c.c_int)(hwnd, index)


class _LayoutBackend:
    def __init__(self, desktop, identity: WindowIdentity):
        self.desktop = desktop
        self.identity = identity

    def validate(self) -> None:
        self.desktop.validate(self.identity)

    validate_rollback = validate

    def save_original(self, _frame: Rect) -> None:
        pass

    def read(self) -> Rect:
        self.validate()
        return _frame(self.identity.hwnd)

    def set_frame(self, wanted: Rect, sizing: bool, *, wait=True) -> None:
        hwnd = self.identity.hwnd
        self.validate()
        native, visible = _native_frame(hwnd), self.read()
        flags = 0x4000 | 0x0200 | 0x0010 | 0x0004  # async, no owner reorder, activation or z-order change
        if not sizing:
            flags |= 0x0001  # SWP_NOSIZE
        set_window = user("SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT)
        left = round(wanted.x + native.x - visible.x)
        top = round(wanted.y + native.y - visible.y)
        right = round(wanted.max_x + native.max_x - visible.max_x)
        bottom = round(wanted.max_y + native.max_y - visible.max_y)
        with _window_coordinates(hwnd, native, left, top, right, bottom) as dimensions:
            if not set_window(hwnd, None, *dimensions, flags):
                raise AppError("Windows 拒绝改变窗口布局。", "rejected")
        # An async cross-process write is accepted by the system before the application processes it.
        if wait:
            _await(lambda: matches(self.read(), wanted) or not matches(self.read(), visible), timeout=0.22)

    def set_size(self, width: float, height: float) -> None:
        current = self.read()
        self.set_frame(Rect(current.x, current.y, width, height), True)

    def set_position(self, x: float, y: float) -> None:
        current = self.read()
        self.set_frame(Rect(x, y, current.w, current.h), False)


class WindowsDesktop:
    def __init__(self):
        self._lock = RLock()
        self._last_external: WindowIdentity | None = None
        self._ui_pid: int | None = None
        self._tokens: dict[str, WindowIdentity] = {}
        self._salt = secrets.token_bytes(16)
        self._originals: dict[WindowIdentity, tuple[Rect, int | None]] = {}
        self._layout = LayoutTransaction()
        self._drags: dict[WindowIdentity, tuple[Rect, tuple[int, int]]] = {}

    def set_ui_pid(self, pid: int | None) -> None:
        self._ui_pid = pid

    def _is_own(self, hwnd: int, identity: WindowIdentity | None = None) -> bool:
        if identity is not None and identity.pid in {os.getpid(), self._ui_pid}:
            return True
        title = _title(hwnd)
        return title.startswith(("搞操作 V", "搞操作 Windows", "搞操作 ·"))

    def _window(self, hwnd: int) -> tuple[WindowIdentity, str] | None:
        if not hwnd or not _window_flag("IsWindowVisible", hwnd) or _style(hwnd, -20) & 0x80:  # WS_EX_TOOLWINDOW
            return None
        title = _title(hwnd)
        if not title or title == "Program Manager":
            return None
        identity = _identity(hwnd)
        if identity is None or self._is_own(hwnd, identity) or identity.class_name in {"Progman", "WorkerW", "Shell_TrayWnd"}:
            return None
        cloaked = w.DWORD()
        if _dwm_attribute(hwnd, 14, cloaked) and cloaked.value:  # DWMWA_CLOAKED
            return None
        return identity, title

    def _id_for(self, identity: WindowIdentity) -> str:
        body = repr((identity.hwnd, identity.pid, identity.thread, identity.creation, identity.class_name)).encode("utf-8")
        identifier = hashlib.blake2s(body, key=self._salt, digest_size=16).hexdigest()
        self._tokens[identifier] = identity
        return identifier

    def validate(self, identity: WindowIdentity) -> None:
        if not is_input_desktop():
            raise AppError("当前不在普通 Windows 交互桌面。", "rejected")
        window = self._window(identity.hwnd)
        if window is None or window[0] != identity:
            raise AppError("目标窗口已经关闭、切换到其他桌面或身份已变化。请重新选择。", "changed")

    def target(self, target_id: str) -> WindowIdentity:
        with self._lock:
            identity = self._tokens.get(target_id) if isinstance(target_id, str) else None
            if identity is None:
                raise AppError("请在窗口总览中重新选择目标窗口。", "changed")
            self.validate(identity)
            return identity

    def observe_foreground(self) -> WindowIdentity | None:
        with self._lock:
            if not is_input_desktop():
                self._last_external = None
                return None
            hwnd = _foreground()
            window = self._window(hwnd)
            if window is not None:
                self._last_external = window[0]
            elif not self._is_own(hwnd, _identity(hwnd)):
                self._last_external = None
            return window[0] if window is not None else None

    def capture_external(self, mode="frontmost") -> WindowIdentity:
        with self._lock:
            if mode not in {"frontmost", "underPointer"}:
                raise AppError("窗口目标方式无效。", "invalid")
            if mode == "underPointer":
                point = self._pointer()
                hwnd = user("WindowFromPoint", w.HWND, w.POINT)(w.POINT(*point))
                root = user("GetAncestor", w.HWND, w.HWND, w.UINT)(hwnd, 2) if hwnd else None
                window = self._window(int(root or 0))
                identity = window[0] if window else None
            else:
                identity = self.observe_foreground() or self._last_external
            if identity is None:
                raise AppError("请先选择一个外部应用窗口。", "missing")
            self.validate(identity)
            return identity

    def require_foreground(self, identity: WindowIdentity) -> None:
        self.validate(identity)
        if _foreground() != identity.hwnd:
            raise AppError("目标窗口已不在前台。", "changed")

    def focus_target(self, identity: WindowIdentity, *, from_target: WindowIdentity | None = None) -> None:
        self.validate(identity)
        previous = _foreground()
        if previous == identity.hwnd:
            return
        if from_target is not None:
            self.require_foreground(from_target)
        if not ((from_target and previous == from_target.hwnd) or self._is_own(previous, _identity(previous))):
            raise AppError("前台窗口已变化，已停止切换焦点。", "changed")
        if _window_flag("IsIconic", identity.hwnd):
            self._show(identity, 4, "IsIconic", False)
        self.validate(identity)
        foreground = _foreground()
        if foreground != identity.hwnd and foreground != previous:
            raise AppError("前台窗口已变化，已停止切换焦点。", "changed")
        if not user("SetForegroundWindow", w.BOOL, w.HWND)(identity.hwnd) or not _await(lambda: _foreground() == identity.hwnd):
            raise AppError("Windows 限制了后台程序切换焦点，请手动选择目标窗口。", "rejected")
        self.require_foreground(identity)

    def overview(self, same_application=False) -> dict:
        with self._lock, physical_coordinates():
            if not is_input_desktop():
                raise AppError("当前 Windows 会话没有可用交互桌面。", "rejected")
            match = self.capture_external() if same_application else None
            rows = []
            live = set()
            for hwnd in _enumerate_windows():
                window = self._window(hwnd)
                if window is None:
                    continue
                identity, title = window
                live.add(identity)
                if match and (identity.pid, identity.creation) != (match.pid, match.creation):
                    continue
                try:
                    frame = _frame(hwnd)
                except AppError:
                    continue
                rows.append({
                    "id": self._id_for(identity), "title": title, "application": identity.application,
                    "hwnd": hwnd, "pid": identity.pid, **frame.as_dict(),
                    "minimized": _window_flag("IsIconic", hwnd), "maximized": _window_flag("IsZoomed", hwnd),
                    "canRestore": identity in self._originals,
                })
            self._tokens = {key: identity for key, identity in self._tokens.items() if identity in live}
            self._originals = {identity: frame for identity, frame in self._originals.items() if _identity(identity.hwnd) == identity}
            return {"windows": rows, "displays": [display.public() for display in _displays()]}

    def _show(self, identity: WindowIdentity, command: int, flag: str, value: bool) -> None:
        self.validate(identity)
        hwnd = identity.hwnd
        if _window_flag(flag, hwnd) == value:
            return
        if not user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)(hwnd, command) or not _await(lambda: _window_flag(flag, hwnd) == value):
            raise AppError("Windows 未确认所请求的窗口状态。", "rejected")
        self.validate(identity)

    def _siblings(self, identity: WindowIdentity) -> list[WindowIdentity]:
        found = []
        for hwnd in _enumerate_windows():
            window = self._window(hwnd)
            if window and (window[0].pid, window[0].creation) == (identity.pid, identity.creation):
                found.append(window[0])
        return sorted(found, key=lambda item: item.hwnd)

    def _state(self, action: str, identity: WindowIdentity, confirmed: bool) -> dict:
        hwnd = identity.hwnd
        if action == "focus":
            self.focus_target(identity)
        elif action == "minimize":
            self._show(identity, 7, "IsIconic", True)  # SW_SHOWMINNOACTIVE
        elif action == "toggleFullScreen":
            was_maximized = _window_flag("IsZoomed", hwnd)
            self._show(identity, 4 if was_maximized else 3, "IsZoomed", not was_maximized)
        elif action == "close":
            if not confirmed:
                raise AppError("关闭窗口前请明确确认。", "confirm")
            self.validate(identity)
            if not user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, 0x0010, 0, 0):
                raise AppError("Windows 拒绝向目标提交关闭请求。", "rejected")
            closed = _await(lambda: _identity(hwnd) != identity, timeout=0.25)
            return {"action": action, "submitted": True, "closed": closed, "exact": closed}
        elif action in {"minimizeAll", "unminimizeAll"}:
            changed = 0
            errors = 0
            minimizing = action == "minimizeAll"
            for sibling in self._siblings(identity):
                try:
                    self._show(sibling, 7 if minimizing else 4, "IsIconic", minimizing)
                    changed += 1
                except AppError:
                    errors += 1
            if not changed:
                raise AppError("Windows 未确认任何窗口完成状态切换。", "rejected")
            return {"action": action, "applied": True, "exact": errors == 0, "confirmed": changed, "failed": errors}
        elif action in {"nextWindow", "previousWindow"}:
            siblings = self._siblings(identity)
            if len(siblings) < 2:
                raise AppError("此应用当前只有一个可操作窗口。", "missing")
            step = 1 if action == "nextWindow" else -1
            next_window = siblings[(siblings.index(identity) + step) % len(siblings)]
            self.focus_target(next_window, from_target=identity if _foreground() == hwnd else None)
            identity = next_window
        return {"action": action, "applied": True, "exact": True, "targetID": self._id_for(identity)}

    def perform(self, action: str, target_id=None, mode="frontmost", *, identity=None, confirmed=False) -> dict:
        with self._lock, physical_coordinates():
            identity = identity or (self.target(target_id) if target_id is not None else self.capture_external(mode))
            self.validate(identity)
            if action in {"focus", "minimize", "minimizeAll", "unminimizeAll", "close", "toggleFullScreen", "nextWindow", "previousWindow"}:
                return self._state(action, identity, confirmed)
            screens = [display.work for display in _displays()]
            saved = self._originals.get(identity)
            if action == "restore" and saved is None:
                raise AppError("此窗口没有可恢复的位置记录。", "missing")
            hwnd = identity.hwnd
            was_state = None
            if _window_flag("IsIconic", hwnd):
                was_state = (7, "IsIconic")
            elif _window_flag("IsZoomed", hwnd):
                was_state = (3, "IsZoomed")
            if was_state:
                self._show(identity, 4, was_state[1], False)
            backend = _LayoutBackend(self, identity)
            original = backend.read()
            try:
                wanted = saved[0] if action == "restore" else target_frame(action, original, screens)
                destination = screens[screen_index(wanted, screens)]
                resizing = action not in {"center", "moveLeft", "moveRight", "moveUp", "moveDown"} or not (
                    matches(Rect(0, 0, wanted.w, wanted.h), Rect(0, 0, original.w, original.h), tolerance=0)
                )
                result = self._layout.execute(wanted, original, destination, resizing, action != "restore", backend)
            except AppError as exc:
                if isinstance(exc, LayoutFailure) and not exc.rollback_verified and saved is None:
                    self._originals[identity] = (original, was_state[0] if was_state else None)
                if was_state:
                    try:
                        self._show(identity, *was_state, True)
                    except AppError as state_error:
                        raise LayoutFailure(f"{exc.message} {state_error.message}", False) from exc
                raise
            if action == "restore":
                if saved[1] is not None:
                    self._show(identity, saved[1], "IsIconic" if saved[1] == 7 else "IsZoomed", True)
                self._originals.pop(identity, None)
            else:
                self._originals[identity] = (original, was_state[0] if was_state else None)
            return {**result, "applied": True, "action": action, "targetID": self._id_for(identity)}

    @staticmethod
    def _pointer() -> tuple[int, int]:
        point = w.POINT()
        if not user("GetCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(point)):
            raise AppError("Windows 未返回指针位置。", "rejected")
        return point.x, point.y

    @staticmethod
    def pointer_is_over(hwnd: int, point: tuple[int, int]) -> bool:
        at_point = user("WindowFromPhysicalPoint", w.HWND, w.POINT)(w.POINT(*point))
        ancestor = user("GetAncestor", w.HWND, w.HWND, w.UINT)
        return bool(at_point and ancestor(at_point, 2) == hwnd and not _window_flag("IsZoomed", hwnd))

    def drag_origin(self, identity: WindowIdentity) -> Rect:
        with self._lock, physical_coordinates():
            self.require_foreground(identity)
            if _window_flag("IsIconic", identity.hwnd) or _window_flag("IsZoomed", identity.hwnd):
                raise AppError("请先还原目标窗口，再拖动它。", "rejected")
            return _frame(identity.hwnd)

    def drag(self, identity: WindowIdentity, original: Rect, start: tuple[int, int], point: tuple[int, int], *, final=False, snap=False) -> None:
        with self._lock, physical_coordinates():
            self.require_foreground(identity)
            if max(abs(point[0] - start[0]), abs(point[1] - start[1])) < 4:
                if not final:
                    return
                point = start
            wanted = Rect(original.x + point[0] - start[0], original.y + point[1] - start[1], original.w, original.h)
            if final and snap and point != start:
                found = snap_target(*point, [display.screen for display in _displays()])
                if found:
                    self.perform(found[0], identity=identity)
                    self._originals[identity] = (original, None)
                    return
            backend = _LayoutBackend(self, identity)
            backend.set_frame(wanted, False, wait=final)
            if final and not matches(backend.read(), original):
                self._originals[identity] = (original, None)
                if not matches(backend.read(), wanted):
                    raise AppError("目标应用只接受了部分拖动距离。", "rejected")

    def track_move(self, hwnd: int, beginning: bool, enable_snap: bool) -> None:
        with self._lock, physical_coordinates():
            window = self._window(hwnd)
            if window is None:
                return
            identity = window[0]
            if beginning:
                self._drags.clear()
            old = self._drags.pop(identity, None)
            if not enable_snap or not is_input_desktop():
                return
            point, frame = self._pointer(), _frame(hwnd)
            if beginning:
                self._drags[identity] = (frame, point)
                return
            if not old or not is_window_drag(old[0], frame, point[0] - old[1][0], point[1] - old[1][1]):
                return
            found = snap_target(*point, [display.screen for display in _displays()])
            if found:
                self.perform(found[0], identity=identity)
                self._originals[identity] = (old[0], None)

    @staticmethod
    def open_settings() -> dict:
        os.startfile("ms-settings:multitasking")
        return {"submitted": True}
