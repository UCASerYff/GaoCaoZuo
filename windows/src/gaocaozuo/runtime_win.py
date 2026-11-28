"""Own the Windows message loop, registered shortcuts and idle warning."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import queue
import time
from dataclasses import dataclass
from threading import Event, RLock, Thread

from gaocaozuo.desktop_win import physical_coordinates
from gaocaozuo.errors import AppError
from gaocaozuo.localization import native_locale, native_text
from gaocaozuo.native_win import bind, is_input_desktop, is_session_active, kernel, user, wait_for_messages
from gaocaozuo.platform_win import last_input
from gaocaozuo.rules_win import ALT, CTRL, SHIFT, WIN, Binding, direction_between
from gaocaozuo.surface_win import surface_colors, window_dpi


_VK_MODIFIERS = {0x10: SHIFT, 0x11: CTRL, 0x12: ALT, 0x5B: WIN, 0x5C: WIN}
_DRAG_UPDATE_INTERVAL = 0.025


class _MouseEvent(c.Structure):
    _fields_ = [("point", w.POINT), ("data", w.DWORD), ("flags", w.DWORD), ("time", w.DWORD), ("extra", c.c_size_t)]


class _WarningPaint(c.Structure):
    _fields_ = [("dc", w.HDC), ("erase", w.BOOL), ("rect", w.RECT), ("restore", w.BOOL), ("update", w.BOOL),
                ("reserved", c.c_ubyte * 32)]


@dataclass
class _Drag:
    identity: object
    start: tuple[int, int]
    point: tuple[int, int]
    original: object = None
    changed: bool = True
    final: bool = False


class _IdleWarning:
    def __init__(self, read_language, read_appearance):
        self.hwnd = 0
        self.label = None
        self.subclass = None
        self.read_language = read_language
        self.read_appearance = read_appearance

    def update(self, warning) -> bool:
        if warning is None:
            if self.hwnd:
                user("DestroyWindow", w.BOOL, w.HWND)(self.hwnd)
                self.hwnd = 0
                self.subclass = None
            self.label = None
            return True
        action, remaining = warning
        key = "将在 {remaining} 秒后锁定屏幕。" if action == "lockScreen" else "将在 {remaining} 秒后启动屏保。"
        with native_locale(self.read_language()):
            title = native_text(key, remaining=remaining)
            hint = native_text("移动鼠标或按键可取消。")
        label = title, hint, surface_colors(self.read_appearance())
        if label != self.label:
            message = f"搞操作 · {title}\r\n\r\n{hint}"
            self.label = label
            if not self.hwnd:
                with physical_coordinates():
                    self._open(message)
            else:
                user("SetWindowTextW", w.BOOL, w.HWND, w.LPCWSTR)(self.hwnd, message)
                user("InvalidateRect", w.BOOL, w.HWND, c.POINTER(w.RECT), w.BOOL)(self.hwnd, None, False)
            if self.hwnd:
                user("UpdateWindow", w.BOOL, w.HWND)(self.hwnd)
        return bool(self.hwnd and user("IsWindowVisible", w.BOOL, w.HWND)(self.hwnd))

    def _open(self, message):
        flags = 0x08000000 | 0x00000080 | 0x00000008  # WS_EX_NOACTIVATE | TOOLWINDOW | TOPMOST
        style = 0x80000000 | 0x00800000 | 0x08000000 | 0x00000001  # POPUP | BORDER | DISABLED | SS_CENTER
        hwnd = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                    c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
        metric = user("GetSystemMetrics", c.c_int, c.c_int)
        inst = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
        screen_width, screen_height = metric(0), metric(1)
        self.hwnd = hwnd(flags, "STATIC", message, style, screen_width // 2, screen_height // 2, 1, 1,
                         None, None, inst, None)
        if not self.hwnd:
            return
        scale = window_dpi(self.hwnd) / 96
        width = min(round(490 * scale), max(1, screen_width - round(48 * scale)))
        height = min(round((136 if width < 390 * scale else 108) * scale), max(1, screen_height))
        position = user("SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT)
        if not position(self.hwnd, w.HWND(-1), (screen_width - width) // 2, (screen_height - height) // 2, width, height, 0x0010):
            self.update(None)
            return
        self._style_window()
        user("ShowWindow", w.BOOL, w.HWND, c.c_int)(self.hwnd, 4)  # SW_SHOWNOACTIVATE

    def _style_window(self):
        subclass_proc = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM, c.c_size_t, c.c_size_t)
        default = bind("comctl32", "DefSubclassProc", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

        @subclass_proc
        def draw(hwnd, message, wparam, lparam, _id, _data):
            if self.label and message in {0x000F, 0x0318}:  # WM_PAINT | WM_PRINTCLIENT
                try:
                    if message == 0x0318 and wparam:
                        self._draw(hwnd, wparam)
                        return 0
                    if self._paint(hwnd):
                        return 0
                except (OSError, RuntimeError, ValueError):
                    pass
            return default(hwnd, message, wparam, lparam)

        subclass = bind("comctl32", "SetWindowSubclass", w.BOOL, w.HWND, subclass_proc, c.c_size_t, c.c_size_t)
        if subclass(self.hwnd, draw, 1, 0):
            self.subclass = draw

    def _paint(self, hwnd):
        state = _WarningPaint()
        dc = user("BeginPaint", w.HDC, w.HWND, c.POINTER(_WarningPaint))(hwnd, c.byref(state))
        if not dc:
            return False
        try:
            self._draw(hwnd, dc)
        finally:
            user("EndPaint", w.BOOL, w.HWND, c.POINTER(_WarningPaint))(hwnd, c.byref(state))
        return True

    def _draw(self, hwnd, dc):
        def color(value):
            red, green, blue = bytes.fromhex(value[1:])
            return red | (green << 8) | (blue << 16)

        title, hint, colors = self.label
        area = w.RECT()
        user("GetClientRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(area))
        scale = window_dpi(hwnd) / 96
        accent = w.RECT(0, 0, round(4 * scale), area.bottom)
        delete = bind("gdi32", "DeleteObject", w.BOOL, w.HANDLE)
        fill = user("FillRect", c.c_int, w.HDC, c.POINTER(w.RECT), w.HANDLE)
        for box, shade in ((area, colors.surface), (accent, colors.accent)):
            brush = bind("gdi32", "CreateSolidBrush", w.HANDLE, w.DWORD)(color(shade))
            try:
                fill(dc, c.byref(box), brush)
            finally:
                if brush:
                    delete(brush)
        bind("gdi32", "SetBkMode", c.c_int, w.HDC, c.c_int)(dc, 1)  # TRANSPARENT
        draw_text = user("DrawTextW", c.c_int, w.HDC, w.LPCWSTR, c.c_int, c.POINTER(w.RECT), w.UINT)
        create_font = bind("gdi32", "CreateFontW", w.HANDLE, *([c.c_int] * 5), *([w.DWORD] * 8), w.LPCWSTR)
        select = bind("gdi32", "SelectObject", w.HANDLE, w.HDC, w.HANDLE)
        padding, y = round(23 * scale), round(17 * scale)
        for line, pixels, weight, ink in ((title, 21, 600, colors.ink), (hint, 15, 400, colors.subtle)):
            font = create_font(-round(pixels * scale), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, "Microsoft YaHei UI")
            previous = select(dc, font) if font else None
            try:
                bind("gdi32", "SetTextColor", w.DWORD, w.HDC, w.DWORD)(dc, color(ink))
                box = w.RECT(padding, y, area.right - padding, area.bottom)
                y += draw_text(dc, line, -1, c.byref(box), 0x00000810) + round(6 * scale)  # NOPREFIX | WORDBREAK
            finally:
                if previous:
                    select(dc, previous)
                if font:
                    delete(font)


class WindowsRuntime:
    """Run opt-in rules and idle policy while the app is active."""

    def __init__(self, desktop, system, idle, invoke, busy=None, on_tick=None, read_language=None, read_appearance=None):
        self.desktop = desktop
        self.system = system
        self.idle = idle
        self.invoke = invoke
        self.busy = busy or (lambda: False)
        self.on_tick = on_tick or (lambda: None)
        self.read_language = read_language or (lambda: "zh-Hans")
        self.read_appearance = read_appearance or (lambda: "system")
        self._lock = RLock()
        self._stop = Event()
        self._rules: tuple[Binding, ...] = ()
        self._status: dict[str, dict] = {}
        self._last_action: dict | None = None
        self._paused = False
        self._snap = False
        self._drag = False
        self._generation = 0
        self._running = False
        self._thread: Thread | None = None
        self._message_thread_id: int | None = None
        self._worker: Thread | None = None
        self._commands = queue.Queue(maxsize=32)

    def configure(self, rules: list[dict], paused=False, snap=False, drag=False) -> None:
        with self._lock:
            status = {}
            compiled = []
            for rule in rules[:512]:
                if not isinstance(rule, dict):
                    continue
                identifier = str(rule.get("id") or "")
                if not rule.get("enabled") or rule.get("paused") or rule.get("needsReview"):
                    status[identifier] = self._row(identifier, "disabled", "此规则尚未启用。")
                    continue
                if rule.get("script") or rule.get("kind", "action") != "action":
                    status[identifier] = self._row(identifier, "unavailable", "Windows 输入规则仅运行应用动作。")
                    continue
                binding = Binding.from_rule(rule)
                if binding is None:
                    status[identifier] = self._row(identifier, "unavailable", "请为规则配置 Windows 快捷键、鼠标按钮或绘图手势。")
                    continue
                status[identifier] = self._row(identifier, "paused" if paused else "pending", "运行时将重新检查此规则。")
                compiled.append(binding)
            self._rules = tuple(compiled)
            self._status = status
            self._paused = bool(paused)
            self._snap = bool(snap)
            self._drag = bool(drag)
            self._generation += 1
        self._wake_message_loop()

    def _wake_message_loop(self) -> None:
        with self._lock:
            thread_id = self._message_thread_id
        if thread_id:
            user("PostThreadMessageW", w.BOOL, w.DWORD, w.UINT, w.WPARAM, w.LPARAM)(thread_id, 0, 0, 0)

    @staticmethod
    def _row(identifier, status, detail):
        return {"id": identifier, "status": status, "detail": detail}

    def _note_rule(self, binding: Binding, status: str, detail: str, generation: int) -> None:
        with self._lock:
            if generation == self._generation and binding.identifier in self._status:
                self._status[binding.identifier] = self._row(binding.identifier, status, detail)

    def snapshot(self) -> dict:
        with self._lock:
            return {"running": self._running, "paused": self._paused, "rules": list(self._status.values()),
                    "lastAction": self._last_action, "gestures": True, "mouseButtons": True, "windowDrag": True}

    def start(self) -> None:
        if self._thread is not None:
            return
        self._worker = Thread(target=self._run_commands, name="gaocaozuo-input-actions", daemon=True)
        self._thread = Thread(target=self._message_loop, name="gaocaozuo-win-events", daemon=True)
        self._worker.start()
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._wake_message_loop()
        try:
            self._commands.put_nowait(None)
        except queue.Full:
            pass  # A queued command already wakes the worker to observe shutdown.
        if self._thread is not None:
            self._thread.join(timeout=2)
        if self._worker is not None:
            self._worker.join(timeout=2)
        self.system.close()

    def _enqueue(self, binding, hwnd, generation) -> None:
        try:
            self._commands.put_nowait((binding, hwnd, generation, time.monotonic()))
        except queue.Full:
            return

    def _run_commands(self) -> None:
        foreground = user("GetForegroundWindow", w.HWND)
        key_state = user("GetAsyncKeyState", c.c_short, c.c_int)
        while not self._stop.is_set():
            command = self._commands.get()
            if command is None or self._stop.is_set():
                return
            binding, hwnd, generation, started = command
            while time.monotonic() - started < 1 and any(key_state(vk) & 0x8000 for vk in _VK_MODIFIERS):
                if self._stop.wait(0.025):
                    return
            with self._lock:
                current = not self._paused and generation == self._generation
            if not current or self._stop.is_set() or time.monotonic() - started >= 1 or not is_input_desktop():
                continue
            try:
                if foreground() != hwnd:
                    raise AppError("触发后前台已变化，未执行动作。", "changed")
                identity = self.desktop.observe_foreground()
                if not binding.matches(identity.application if identity else ""):
                    raise AppError("前台应用与这条规则不匹配。", "changed")
                if binding.action.startswith("window.") and identity is None:
                    identity = self.desktop.capture_external()
                payload = {"inputRuleID": binding.identifier}
                if identity:
                    payload["nativeTarget"] = identity
                self.invoke(binding.action, payload)
                row = self._row(binding.identifier, "submitted", "动作已运行。")
            except AppError as exc:
                row = self._row(binding.identifier, exc.code, exc.message)
            except Exception:
                row = self._row(binding.identifier, "rejected", "运行时未能完成该动作。")
            with self._lock:
                self._last_action = row

    def _idle_tick(self, warning: _IdleWarning) -> None:
        def safety():
            if self._stop.is_set() or not is_input_desktop() or not is_session_active():
                return "当前 Windows 会话不在普通交互桌面。"
            if self.busy():
                return "有进行中的任务，已暂停本次倒计时。"
            return None

        def execute(action):
            return self.system.lock() if action == "lockScreen" else self.system.screensaver()

        self.idle.sample(last_input, safety, warning.update, execute)

    def _message_loop(self) -> None:
        show_warning = _IdleWarning(self.read_language, self.read_appearance)
        peek = user("PeekMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT)
        translate = user("TranslateMessage", w.BOOL, c.POINTER(w.MSG))
        dispatch = user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
        foreground = user("GetForegroundWindow", w.HWND)
        key_state = user("GetAsyncKeyState", c.c_short, c.c_int)
        register = user("RegisterHotKey", w.BOOL, w.HWND, c.c_int, w.UINT, w.UINT)
        unregister = user("UnregisterHotKey", w.BOOL, w.HWND, c.c_int)
        installed: dict[int, Binding] = {}
        mouse_actions: dict[tuple, Binding] = {}
        configuration = None
        right_down = None
        mouse_hook = None
        hwnd_active = 0
        next_tick = 0.0
        next_drag_tick = 0.0
        generation = 0
        window_events = []
        active_target = None
        drag_enabled = False
        dragging = None
        event_type = c.WINFUNCTYPE(None, w.HANDLE, w.DWORD, w.HWND, w.LONG, w.LONG, w.DWORD, w.DWORD)
        hook_type = c.WINFUNCTYPE(c.c_ssize_t, c.c_int, w.WPARAM, w.LPARAM)
        use_mouse = user("SetWindowsHookExW", w.HANDLE, c.c_int, hook_type, w.HINSTANCE, w.DWORD)
        stop_mouse = user("UnhookWindowsHookEx", w.BOOL, w.HANDLE)
        next_mouse = user("CallNextHookEx", c.c_ssize_t, w.HANDLE, c.c_int, w.WPARAM, w.LPARAM)
        hook_event = user("SetWinEventHook", w.HANDLE, w.DWORD, w.DWORD, w.HMODULE, event_type, w.DWORD, w.DWORD, w.DWORD)
        stop_event = user("UnhookWinEvent", w.BOOL, w.HANDLE)

        def modifiers():
            mask = 0
            for vk, flag in _VK_MODIFIERS.items():
                if key_state(vk) & 0x8000:
                    mask |= flag
            return mask

        @event_type
        def event(_handle, kind, hwnd, identifier, child, _thread, _timestamp):
            if not identifier and not child and hwnd and len(window_events) < 48:
                window_events.append((kind, int(hwnd)))

        @hook_type
        def mouse(code, message, param):
            nonlocal right_down, dragging
            button_messages = {0x0204, 0x0205, 0x0207, 0x020B}
            drag_messages = {0x0200, 0x0201, 0x0202}
            if code < 0 or not ((mouse_actions and message in button_messages) or (drag_enabled and message in drag_messages)):
                return next_mouse(None, code, message, param)
            if message == 0x0200 and dragging is None:
                return next_mouse(None, code, message, param)
            datum = c.cast(param, c.POINTER(_MouseEvent)).contents
            if datum.flags & 3:  # synthetic or lower-integrity input
                return next_mouse(None, code, message, param)
            point = datum.point.x, datum.point.y
            if dragging is not None and message in {0x0200, 0x0202}:
                dragging.point = point
                dragging.changed = True
                if message == 0x0202:
                    dragging.final = True
                    return 1
                return next_mouse(None, code, message, param)
            hwnd = int(foreground() or 0)
            mask = modifiers()
            if message == 0x0201 and hwnd == hwnd_active and active_target and mask == ALT:
                if self.desktop.pointer_is_over(hwnd, point):
                    dragging = _Drag(active_target, point, point)
                    return 1
            if hwnd and hwnd == hwnd_active:
                binding = None
                if message in {0x0207, 0x020B}:
                    button = 2 if message == 0x0207 else {1: 3, 2: 4}.get(datum.data >> 16)
                    binding = mouse_actions.get(("mouseButton", mask, button))
                elif message == 0x0204:
                    if mask & ALT:
                        right_down = (hwnd, mask, point)
                elif message == 0x0205 and right_down:
                    target, source_modifiers, start = right_down
                    if hwnd == target and mask == source_modifiers:
                        binding = mouse_actions.get(("gesture", mask, direction_between(start, point)))
                if binding:
                    self._enqueue(binding, hwnd, generation)
            if message == 0x0205:
                right_down = None
            return next_mouse(None, code, message, param)

        msg = w.MSG()
        peek(c.byref(msg), None, 0, 0, 0)  # initialize this thread's message queue
        hooks = [hook_event(kind, end, None, event, 0, 0, 2) for kind, end in ((3, 3), (0x000A, 0x000B))]
        try:
            with self._lock:
                self._message_thread_id = kernel("GetCurrentThreadId", w.DWORD)()
                self._running = True
            while not self._stop.is_set():
                while peek(c.byref(msg), None, 0, 0, 1):
                    if msg.message == 0x0312:  # WM_HOTKEY
                        binding = installed.get(msg.wParam)
                        mask, vk = (msg.lParam & 0xFFFF), ((msg.lParam >> 16) & 0xFFFF)
                        if binding and (mask, vk) == binding.key[1:] and foreground() == hwnd_active:
                            self._enqueue(binding, hwnd_active, generation)
                    else:
                        translate(c.byref(msg))
                        dispatch(c.byref(msg))

                moment = time.monotonic()
                with self._lock:
                    generation, rules, paused, snap, drag = self._generation, self._rules, self._paused, self._snap, self._drag
                current = int(foreground() or 0) if (rules and not paused) or snap or drag else 0
                interactive = bool(current and is_input_desktop())
                desired = generation, current, interactive
                if configuration != desired:
                    for handle in installed:
                        unregister(None, handle)
                    installed.clear()
                    mouse_actions.clear()
                    right_down = None
                    hwnd_active = current
                    active_target = self.desktop.observe_foreground() if interactive else None
                    drag_enabled = bool(drag and active_target)
                    application = active_target.application if active_target else ""
                    self._register_bindings(rules, application, paused, interactive, generation, register, installed, mouse_actions)
                    if (mouse_actions or drag_enabled) and not mouse_hook:
                        module = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
                        mouse_hook = use_mouse(14, mouse, module, 0)  # WH_MOUSE_LL
                        if not mouse_hook:
                            for binding in mouse_actions.values():
                                self._note_rule(binding, "rejected", "Windows 拒绝注册鼠标事件监听。", generation)
                            if drag_enabled:
                                with self._lock:
                                    self._last_action = self._row("window.drag", "rejected", "Windows 拒绝注册窗口拖动所需的鼠标事件。")
                    elif not mouse_actions and not drag_enabled and mouse_hook:
                        stop_mouse(mouse_hook)
                        mouse_hook = None
                    configuration = desired

                if dragging is not None and (not drag_enabled or dragging.identity != active_target):
                    dragging = None
                if dragging is not None and dragging.changed and (dragging.final or moment >= next_drag_tick):
                    try:
                        if dragging.original is None:
                            dragging.original = self.desktop.drag_origin(dragging.identity)
                        if dragging.point != dragging.start or dragging.final:
                            self.desktop.drag(dragging.identity, dragging.original, dragging.start, dragging.point,
                                              final=dragging.final, snap=snap)
                        dragging.changed = False
                        next_drag_tick = moment + _DRAG_UPDATE_INTERVAL
                        if dragging.final:
                            dragging = None
                    except AppError as exc:
                        with self._lock:
                            self._last_action = self._row("window.drag", exc.code, exc.message)
                        dragging = None

                if window_events:
                    pending = window_events[:]
                    window_events.clear()
                    for kind, hwnd in pending:
                        if snap and kind in {0x000A, 0x000B}:
                            try:
                                self.desktop.track_move(hwnd, kind == 0x000A, True)
                            except AppError as exc:
                                with self._lock:
                                    self._last_action = self._row("window.snap", exc.code, exc.message)

                if moment >= next_tick:
                    next_tick = moment + 0.25
                    self._idle_tick(show_warning)
                    try:
                        self.on_tick()
                    except Exception:
                        pass
                if self._stop.is_set():
                    break
                deadline = next_tick
                if dragging is not None and dragging.changed:
                    deadline = min(deadline, next_drag_tick)
                wait_for_messages(deadline - time.monotonic())
        finally:
            if mouse_hook:
                stop_mouse(mouse_hook)
            for hook in hooks:
                if hook:
                    stop_event(hook)
            for handle in installed:
                unregister(None, handle)
            show_warning.update(None)
            with self._lock:
                self._message_thread_id = None
                self._running = False

    def _register_bindings(self, rules, application, paused, interactive, generation, register, installed, mouse_actions):
        matched = {}
        for binding in rules:
            if paused or not interactive:
                self._note_rule(binding, "paused", "输入规则已暂停。", generation)
            elif not binding.matches(application):
                self._note_rule(binding, "outOfScope", "当前前台应用不在此规则范围内。", generation)
            else:
                matched.setdefault(binding.key, []).append(binding)
        for index, (key, candidates) in enumerate(matched.items(), 1):
            if len(candidates) != 1:
                for binding in candidates:
                    self._note_rule(binding, "conflict", "有多条有效规则使用同一触发方式。", generation)
                continue
            binding = candidates[0]
            if key[0] == "hotkey":
                if not register(None, index, key[1] | 0x4000, key[2]):
                    self._note_rule(binding, "rejected", "Windows 或其他应用正在使用此快捷键。", generation)
                    continue
                installed[index] = binding
            else:
                mouse_actions[key] = binding
            self._note_rule(binding, "active", "已在当前会话注册。", generation)
