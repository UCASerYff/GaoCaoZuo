"""窗口几何与可注入后端的布局事务。测试不移动真实窗口。"""

from __future__ import annotations

from dataclasses import dataclass

from gaocaozuo.errors import AppError, LayoutFailure


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    @property
    def max_x(self) -> float:
        return self.x + self.w

    @property
    def max_y(self) -> float:
        return self.y + self.h

    @property
    def mid_x(self) -> float:
        return self.x + self.w / 2

    @property
    def mid_y(self) -> float:
        return self.y + self.h / 2

    def as_dict(self) -> dict:
        return {"x": self.x, "y": self.y, "width": self.w, "height": self.h}


def valid(rect: Rect) -> bool:
    values = (rect.x, rect.y, rect.w, rect.h)
    return all(value == value and abs(value) != float("inf") for value in values) and rect.w > 0 and rect.h > 0


def matches(lhs: Rect, rhs: Rect, tolerance: float = 4) -> bool:
    return (
        abs(lhs.x - rhs.x) <= tolerance
        and abs(lhs.y - rhs.y) <= tolerance
        and abs(lhs.w - rhs.w) <= tolerance
        and abs(lhs.h - rhs.h) <= tolerance
    )


def _intersection_area(a: Rect, b: Rect) -> float:
    w = min(a.max_x, b.max_x) - max(a.x, b.x)
    h = min(a.max_y, b.max_y) - max(a.y, b.y)
    if w <= 0 or h <= 0:
        return 0
    return w * h


def screen_index(window: Rect, screens: list[Rect]) -> int | None:
    if not screens:
        return None
    areas = [_intersection_area(screen, window) for screen in screens]
    largest = max(areas)
    if largest > 0:
        return areas.index(largest)
    return min(
        range(len(screens)),
        key=lambda index: (screens[index].mid_x - window.mid_x) ** 2 + (screens[index].mid_y - window.mid_y) ** 2,
    )


def _fraction(screen: Rect, x: float, y: float, w: float, h: float) -> Rect:
    return Rect(screen.x + screen.w * x, screen.y + screen.h * y, screen.w * w, screen.h * h)


def _centered(size_w: float, size_h: float, destination: Rect) -> Rect:
    width = min(size_w, destination.w)
    height = min(size_h, destination.h)
    return Rect(destination.mid_x - width / 2, destination.mid_y - height / 2, width, height)


def target_frame(action: str, current: Rect, screens: list[Rect]) -> Rect:
    index = screen_index(current, screens)
    if index is None:
        raise AppError("没有可用的显示器。", "invalid")
    screen = screens[index]
    if action == "leftHalf":
        return _fraction(screen, 0, 0, 0.5, 1)
    if action == "rightHalf":
        return _fraction(screen, 0.5, 0, 0.5, 1)
    if action == "topHalf":
        return _fraction(screen, 0, 0, 1, 0.5)
    if action == "bottomHalf":
        return _fraction(screen, 0, 0.5, 1, 0.5)
    if action == "topLeft":
        return _fraction(screen, 0, 0, 0.5, 0.5)
    if action == "topRight":
        return _fraction(screen, 0.5, 0, 0.5, 0.5)
    if action == "bottomLeft":
        return _fraction(screen, 0, 0.5, 0.5, 0.5)
    if action == "bottomRight":
        return _fraction(screen, 0.5, 0.5, 0.5, 0.5)
    if action == "thirdLeft":
        return _fraction(screen, 0, 0, 1 / 3, 1)
    if action == "thirdCenter":
        return _fraction(screen, 1 / 3, 0, 1 / 3, 1)
    if action == "thirdRight":
        return _fraction(screen, 2 / 3, 0, 1 / 3, 1)
    if action == "maximize":
        return Rect(screen.x, screen.y, screen.w, screen.h)
    if action == "center":
        return _centered(current.w, current.h, screen)
    if action in {"smaller", "larger"}:
        scale = 0.9 if action == "smaller" else 1.1
        width = min(screen.w, max(160, current.w * scale))
        height = min(screen.h, max(100, current.h * scale))
        return Rect(
            min(max(current.mid_x - width / 2, screen.x), screen.max_x - width),
            min(max(current.mid_y - height / 2, screen.y), screen.max_y - height),
            width,
            height,
        )
    if action in {"nextDisplay", "previousDisplay"}:
        if len(screens) < 2:
            raise AppError("当前只有一个显示器。", "invalid")
        step = 1 if action == "nextDisplay" else len(screens) - 1
        destination = screens[(index + step) % len(screens)]
        width = min(current.w, destination.w)
        height = min(current.h, destination.h)
        relative_x = (current.x - screen.x) / max(1, screen.w - current.w)
        relative_y = (current.y - screen.y) / max(1, screen.h - current.h)
        relative_x = max(0, min(1, relative_x))
        relative_y = max(0, min(1, relative_y))
        return Rect(
            destination.x + relative_x * (destination.w - width),
            destination.y + relative_y * (destination.h - height),
            width,
            height,
        )
    if action == "nearMaximize":
        dx = min(40, screen.w / 10)
        dy = min(40, screen.h / 10)
        return Rect(screen.x + dx, screen.y + dy, screen.w - dx * 2, screen.h - dy * 2)
    if action == "centerHalf":
        return _fraction(screen, 0.25, 0, 0.5, 1)
    if action == "leftTwoThirds":
        return _fraction(screen, 0, 0, 2 / 3, 1)
    if action == "rightTwoThirds":
        return _fraction(screen, 1 / 3, 0, 2 / 3, 1)
    if action == "maximizeHeight":
        return Rect(current.x, screen.y, current.w, screen.h)
    if action == "maximizeWidth":
        return Rect(screen.x, current.y, screen.w, current.h)
    if action == "quarterFirst":
        return _fraction(screen, 0, 0, 0.25, 1)
    if action == "quarterSecond":
        return _fraction(screen, 0.25, 0, 0.25, 1)
    if action == "quarterThird":
        return _fraction(screen, 0.5, 0, 0.25, 1)
    if action == "quarterFourth":
        return _fraction(screen, 0.75, 0, 0.25, 1)
    if action == "leftThreeQuarters":
        return _fraction(screen, 0, 0, 0.75, 1)
    if action == "rightThreeQuarters":
        return _fraction(screen, 0.25, 0, 0.75, 1)
    if action == "sixthTopLeft":
        return _fraction(screen, 0, 0, 1 / 3, 0.5)
    if action == "sixthTopCenter":
        return _fraction(screen, 1 / 3, 0, 1 / 3, 0.5)
    if action == "sixthTopRight":
        return _fraction(screen, 2 / 3, 0, 1 / 3, 0.5)
    if action == "sixthBottomLeft":
        return _fraction(screen, 0, 0.5, 1 / 3, 0.5)
    if action == "sixthBottomCenter":
        return _fraction(screen, 1 / 3, 0.5, 1 / 3, 0.5)
    if action == "sixthBottomRight":
        return _fraction(screen, 2 / 3, 0.5, 1 / 3, 0.5)
    if action == "moveLeft":
        return Rect(screen.x, current.y, current.w, current.h)
    if action == "moveRight":
        return Rect(screen.max_x - current.w, current.y, current.w, current.h)
    if action == "moveUp":
        return Rect(current.x, screen.y, current.w, current.h)
    if action == "moveDown":
        return Rect(current.x, screen.max_y - current.h, current.w, current.h)
    raise AppError("此动作需要窗口状态操作，不能仅计算尺寸。", "invalid")


def fitted_frame(size_w: float, size_h: float, requested: Rect, work_area: Rect | None) -> Rect:
    def anchor(start: float, end: float, area_start: float | None, area_end: float | None) -> float:
        if area_start is not None and area_end is not None:
            leading = abs(start - area_start)
            trailing = abs(area_end - end)
            edge_inset = max(4, (end - start) * 0.1)
            if leading <= trailing and leading <= edge_inset:
                return 0
            if trailing < leading and trailing <= edge_inset:
                return 1
        return 0.5

    x = requested.x + (requested.w - size_w) * anchor(
        requested.x, requested.max_x, work_area.x if work_area else None, work_area.max_x if work_area else None
    )
    y = requested.y + (requested.h - size_h) * anchor(
        requested.y, requested.max_y, work_area.y if work_area else None, work_area.max_y if work_area else None
    )
    if work_area is not None:
        x = min(max(x, work_area.x), max(work_area.x, work_area.max_x - size_w))
        y = min(max(y, work_area.y), max(work_area.y, work_area.max_y - size_h))
    return Rect(x, y, size_w, size_h)


def snap_target(pointer_x: float, pointer_y: float, screens: list[Rect], threshold: float = 24) -> tuple[str, Rect] | None:
    index = None
    for i, screen in enumerate(screens):
        if screen.x <= pointer_x < screen.max_x and screen.y <= pointer_y < screen.max_y:
            index = i
            break
    if index is None:
        return None
    frame = screens[index]
    left = pointer_x <= frame.x + threshold
    right = pointer_x >= frame.max_x - threshold
    top = pointer_y <= frame.y + threshold
    bottom = pointer_y >= frame.max_y - threshold
    action = None
    if left and top:
        action = "topLeft"
    elif right and top:
        action = "topRight"
    elif left and bottom:
        action = "bottomLeft"
    elif right and bottom:
        action = "bottomRight"
    elif left:
        action = "leftHalf"
    elif right:
        action = "rightHalf"
    elif top:
        action = "maximize"
    if action is None:
        return None
    return action, frame


def is_window_drag(initial: Rect, current: Rect, pointer_dx: float, pointer_dy: float) -> bool:
    moved = (current.x - initial.x) ** 2 + (current.y - initial.y) ** 2
    pointer = pointer_dx ** 2 + pointer_dy ** 2
    return abs(initial.w - current.w) <= 4 and abs(initial.h - current.h) <= 4 and moved >= 36 and pointer >= 64


def restore_focus(target_pid: int, own_pid: int, frontmost, validate, raise_target, activate) -> None:
    if target_pid == own_pid:
        raise AppError("不能将搞操作自己的窗口作为本次操作目标。", "invalid")
    validate()
    foreground = frontmost()
    if foreground not in {target_pid, own_pid}:
        raise AppError("前台应用已变化，已停止切换窗口；请重新选择需要操作的窗口。", "changed")
    raise_target()
    validate()
    if not activate():
        raise AppError("窗口布局已调整，但系统拒绝激活目标应用。请手动切回该窗口查看。", "rejected")
    validate()
    raise_target()


class LayoutTransaction:
    def __init__(self):
        self.busy = False

    def execute(self, requested: Rect, original: Rect, work_area: Rect | None, resize: bool, allow_constrained: bool, backend) -> dict:
        if self.busy:
            raise AppError("窗口操作正在进行，请稍候再试。", "busy")
        if not valid(requested) or not valid(original):
            raise AppError("窗口布局包含无效的位置或尺寸。", "invalid")
        backend.validate()
        self.busy = True
        try:
            backend.save_original(original)

            def write_frame(frame: Rect, resizing: bool, rolling_back: bool = False) -> None:
                if rolling_back:
                    backend.validate_rollback()
                else:
                    backend.validate()
                if hasattr(backend, "set_frame"):
                    backend.set_frame(frame, resizing)
                    return
                if resizing:
                    try:
                        backend.set_size(frame.w, frame.h)
                    except AppError:
                        pass
                if rolling_back:
                    backend.validate_rollback()
                else:
                    backend.validate()
                try:
                    backend.set_position(frame.x, frame.y)
                except AppError:
                    pass
                if resizing:
                    if rolling_back:
                        backend.validate_rollback()
                    else:
                        backend.validate()
                    try:
                        backend.set_size(frame.w, frame.h)
                    except AppError:
                        pass

            try:
                write_frame(requested, resize)
                actual = backend.read()
                if not valid(actual):
                    raise AppError("目标窗口返回了无效尺寸。", "invalid")
                if matches(actual, requested):
                    return {"requested": requested.as_dict(), "actual": actual.as_dict(), "exact": True}
                if resize:
                    try:
                        backend.set_size(actual.w, requested.h)
                    except AppError:
                        pass
                    actual = backend.read()
                    if abs(actual.w - requested.w) > 4:
                        try:
                            backend.set_size(requested.w, actual.h)
                        except AppError:
                            pass
                        actual = backend.read()
                if not allow_constrained:
                    try:
                        backend.set_position(requested.x, requested.y)
                    except AppError:
                        pass
                    actual = backend.read()
                    if not matches(actual, requested):
                        raise AppError("目标应用拒绝恢复记录中的窗口位置或尺寸。", "rejected")
                    return {"requested": requested.as_dict(), "actual": actual.as_dict(), "exact": True}
                fitted = fitted_frame(actual.w, actual.h, requested, work_area)
                try:
                    backend.set_position(fitted.x, fitted.y)
                except AppError:
                    pass
                actual = backend.read()
                if not matches(actual, fitted):
                    raise AppError("目标应用拒绝将允许的窗口尺寸贴到目标区域，未完成此布局。", "rejected")
                if matches(actual, original):
                    raise AppError("目标应用未接受所请求的窗口布局。", "rejected")
                return {"requested": requested.as_dict(), "actual": actual.as_dict(), "exact": matches(actual, requested)}
            except AppError as exc:
                restored = False
                try:
                    write_frame(original, True, rolling_back=True)
                    restored = matches(backend.read(), original)
                except AppError:
                    restored = False
                raise LayoutFailure(exc.message, restored) from exc
        finally:
            self.busy = False
