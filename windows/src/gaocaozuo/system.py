"""锁屏、睡眠和保持唤醒只报告已提交的请求。屏保不等于锁屏。"""

from __future__ import annotations

import math
import time
from threading import RLock

from gaocaozuo.errors import AppError

LOCK_MESSAGE = "已提交 Windows 锁屏请求，系统锁定结果尚未确认。"
SAVER_MESSAGE = "已提交屏保启动请求。屏保不等于锁定屏幕，密码要求由 Windows 设置决定。"
SLEEP_MESSAGE = "已提交 Windows 睡眠请求，系统睡眠结果尚未确认。"


class IdlePolicy:
    def __init__(self, config: dict):
        self.config = config
        self.state = "disabled"
        self.requested = False
        self._lock = RLock()
        self._observed_at: float | None = None
        self._last_poll: float | None = None
        self._last_input: int | None = None
        self._deadline: float | None = None
        self._settles_at = 0.0
        self._remaining: int | None = None
        self._detail = ""
        self.apply_config(config)

    def apply_config(self, config: dict) -> None:
        with self._lock:
            self.config = dict(config)
            self.requested = False
            self.cancel()

    def cancel(self) -> dict:
        with self._lock:
            self._observed_at = self._last_poll = self._deadline = None
            self._remaining = None
            self._detail = ""
            if not self.config.get("enabled"):
                self.state = "disabled"
            else:
                self.state = "waitingForActivity" if self.requested else "observing"
            return self.snapshot()

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "state": self.state,
                "enabled": bool(self.config.get("enabled")),
                "remaining": self._remaining,
                "detail": self._detail,
                "confirmedLocked": False,
            }

    def sample(self, read_idle, safety, alert, execute, now=time.monotonic) -> None:
        """Observe real session activity and run only an on-screen warning's live deadline."""
        with self._lock:
            if not self.config.get("enabled") or self.state == "failed":
                alert(None)
                return
            moment = now()
            unsafe = safety()
            try:
                timestamp, elapsed = read_idle() if not unsafe else (None, 0)
            except AppError as exc:
                unsafe = exc.message
                timestamp, elapsed = None, 0
            if unsafe:
                alert(None)
                self._observed_at = self._deadline = self._last_poll = self._remaining = None
                self.state = "paused"
                self._detail = unsafe
                return
            changed = self._last_input is not None and self._last_input != timestamp
            stale = self._last_poll is None or not 0 <= moment - self._last_poll <= 5
            if stale or (changed and moment >= self._settles_at) or self._observed_at is None:
                self._observed_at = moment
                self._deadline = self._remaining = None
                alert(None)
            if changed and moment >= self._settles_at:
                self.requested = False
            self._last_input = timestamp
            self._last_poll = moment
            if self.requested:
                self.state = "waitingForActivity"
                return
            self._detail = ""
            if min(elapsed, moment - self._observed_at) < float(self.config.get("idleSeconds") or 300):
                self.state = "observing"
                return
            action = self.config.get("action") or "lockScreen"
            if self._deadline is None:
                self._deadline = moment + float(self.config.get("warningSeconds") or 15)
            if moment < self._deadline:
                self._remaining = max(1, math.ceil(self._deadline - moment))
                if not alert((action, self._remaining)):
                    self._observed_at = self._deadline = self._remaining = None
                    self.state = "paused"
                    self._detail = "Windows 未显示闲置提醒。"
                    return
                self.state = "countdown"
                return
            alert(None)
            self._remaining = self._deadline = None
            try:
                if safety() or read_idle()[0] != timestamp:
                    self._observed_at = moment
                    self.state = "observing"
                    return
                self.requested = True
                self._settles_at = now() + 2
                self._detail = execute(action).get("message", "")
                self.state = "waitingForActivity"
            except AppError as exc:
                self.state = "failed"
                self._detail = exc.message

    def tick(self, idle_seconds: float, activity: bool = False, busy: bool = False) -> dict:
        if not self.config.get("enabled"):
            self.state = "disabled"
            self.requested = False
            return {"state": self.state, "requested": False, "confirmedLocked": False}
        if activity:
            self.state = "observing"
            self.requested = False
            return {"state": self.state, "requested": False, "confirmedLocked": False}
        if busy:
            self.state = "paused"
            return {"state": self.state, "requested": False, "confirmedLocked": False, "detail": "有进行中的任务，已暂停本次倒计时。"}
        idle_limit = float(self.config.get("idleSeconds") or 300)
        warning = float(self.config.get("warningSeconds") or 15)
        if self.requested:
            self.state = "waitingForActivity"
            return {
                "state": self.state,
                "requested": False,
                "confirmedLocked": False,
                "detail": "请求不代表锁定结果已确认；不会在同一闲置周期重复执行，也不会自动解锁。",
            }
        if idle_seconds >= idle_limit:
            self.requested = True
            self.state = "waitingForActivity"
            action = self.config.get("action") or "lockScreen"
            message = LOCK_MESSAGE if action == "lockScreen" else SAVER_MESSAGE
            return {"state": self.state, "requested": True, "confirmedLocked": False, "message": message, "action": action}
        if idle_seconds >= idle_limit - warning:
            remaining = max(0, int(idle_limit - idle_seconds))
            self.state = "countdown"
            return {"state": self.state, "remaining": remaining, "requested": False, "confirmedLocked": False}
        self.state = "observing"
        return {"state": self.state, "requested": False, "confirmedLocked": False}


class SystemGateway:
    def __init__(self, backend):
        self.backend = backend
        self.awake = False

    def lock(self) -> dict:
        if not self.backend.lock():
            raise AppError("系统拒绝了锁屏请求，未伪称已锁定。", "rejected")
        return {"message": LOCK_MESSAGE, "confirmedLocked": False}

    def screensaver(self) -> dict:
        if not self.backend.screensaver():
            raise AppError("系统拒绝了屏保请求。屏保也不等于锁定。", "rejected")
        return {"message": SAVER_MESSAGE, "confirmedLocked": False}

    def sleep(self) -> dict:
        if not self.backend.sleep():
            raise AppError("系统拒绝了睡眠请求，未伪称已经睡眠。", "rejected")
        return {"message": SLEEP_MESSAGE, "confirmedAsleep": False}

    def set_awake(self, enabled: bool) -> dict:
        if not self.backend.set_awake(enabled):
            raise AppError("系统拒绝了保持唤醒请求，状态未改变。", "rejected")
        self.awake = enabled
        return {"awake": self.awake}

    def media(self, name: str) -> dict:
        if not self.backend.media(name):
            raise AppError(f"系统没有接受“{name}”媒体键，未伪造成功。", "rejected")
        return {"submitted": name}

    def desktop(self, name: str) -> dict:
        operation = getattr(self.backend, "desktop", None)
        if operation is None:
            raise AppError("当前系统没有 Windows 桌面快捷键接口。", "unavailable")
        if not operation(name):
            raise AppError("Windows 未接受桌面快捷键。请先松开修饰键并回到当前交互桌面。", "rejected")
        return {"submitted": name, "message": "已向 Windows 提交桌面快捷键。"}

    def close(self) -> None:
        close = getattr(self.backend, "close", None)
        if close is not None:
            close()


class FakeSystem:
    def __init__(self, accept: bool = True):
        self.accept = accept
        self.calls: list[str] = []
        self.awake = False

    def lock(self) -> bool:
        self.calls.append("lock")
        return self.accept

    def screensaver(self) -> bool:
        self.calls.append("screensaver")
        return self.accept

    def sleep(self) -> bool:
        self.calls.append("sleep")
        return self.accept

    def set_awake(self, enabled: bool) -> bool:
        self.calls.append(f"awake:{enabled}")
        if self.accept:
            self.awake = enabled
        return self.accept

    def media(self, name: str) -> bool:
        self.calls.append(name)
        return self.accept


class UnavailableSystem:
    def lock(self) -> bool:
        raise AppError("当前系统没有锁屏接口，未伪称已锁定。", "unavailable")

    def screensaver(self) -> bool:
        raise AppError("当前系统没有屏保接口。", "unavailable")

    def sleep(self) -> bool:
        raise AppError("当前系统没有睡眠接口，未伪称已经睡眠。", "unavailable")

    def set_awake(self, enabled: bool) -> bool:
        raise AppError("当前系统没有保持唤醒接口。", "unavailable")

    def media(self, name: str) -> bool:
        raise AppError("当前系统没有媒体键接口。", "unavailable")
