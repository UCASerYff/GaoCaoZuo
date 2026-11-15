"""锁屏、睡眠和保持唤醒只报告已提交的请求。屏保不等于锁屏。"""

from __future__ import annotations

from gaocaozuo.errors import AppError

LOCK_MESSAGE = "已提交系统锁屏快捷键请求；系统是否已锁定尚未确认。"
SAVER_MESSAGE = "已提交屏保启动请求；屏保不等于锁定屏幕，是否要求密码由系统设置决定。"
SLEEP_MESSAGE = "已提交系统睡眠请求；是否已经进入睡眠尚未确认。"


class IdlePolicy:
    def __init__(self, config: dict):
        self.config = config
        self.state = "disabled"
        self.requested = False
        self.apply_config(config)

    def apply_config(self, config: dict) -> None:
        self.config = config
        if not config.get("enabled"):
            self.state = "disabled"
            self.requested = False
        elif self.state == "disabled":
            self.state = "observing"

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
