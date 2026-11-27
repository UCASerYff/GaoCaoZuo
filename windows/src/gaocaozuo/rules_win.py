"""Normalize Windows input bindings while retaining portable rule documents."""

from __future__ import annotations

from dataclasses import dataclass
from math import hypot
from pathlib import PureWindowsPath

ALT, CTRL, SHIFT, WIN = 1, 2, 4, 8
_MODIFIERS = {"ALT": ALT, "OPTION": ALT, "CTRL": CTRL, "CONTROL": CTRL, "SHIFT": SHIFT, "WIN": WIN, "WINDOWS": WIN}
_VIRTUAL_KEYS = {
    "TAB": 0x09, "ENTER": 0x0D, "ESC": 0x1B, "ESCAPE": 0x1B, "SPACE": 0x20, "BACKSPACE": 0x08,
    "PAGEUP": 0x21, "PAGEDOWN": 0x22, "END": 0x23, "HOME": 0x24, "LEFT": 0x25, "UP": 0x26,
    "RIGHT": 0x27, "DOWN": 0x28, "INSERT": 0x2D, "DELETE": 0x2E,
    **{f"F{number}": 0x6F + number for number in range(1, 25) if number != 12},
    **{char: ord(char) for char in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"},
}


def _application(value: str) -> str:
    return PureWindowsPath(value.strip()).name.casefold()


def _scope(value) -> frozenset[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        return frozenset()
    return frozenset(filter(None, (_application(item) for item in value)))


def parse_shortcut(shortcut) -> tuple[int, int] | None:
    if not isinstance(shortcut, str):
        return None
    pieces = [piece.strip().upper() for piece in shortcut.split("+")]
    vk = _VIRTUAL_KEYS.get(pieces[-1])
    modifiers = [_MODIFIERS.get(piece) for piece in pieces[:-1]]
    if vk is None or None in modifiers or len(set(modifiers)) != len(modifiers):
        return None
    mask = sum(modifiers)
    if not mask & (CTRL | ALT | WIN):
        return None
    return mask, vk


def _mouse_modifiers(rule: dict, default: int) -> int | None:
    portable = rule.get("modifiers")
    if "mouseModifiers" not in rule and type(portable) is int and portable >= 0:
        if not portable:
            return default
        return sum(mask for index, mask in ((17, SHIFT), (18, CTRL), (19, ALT), (20, WIN)) if portable & (1 << index))
    label = rule.get("mouseModifiers", "")
    if not isinstance(label, str):
        return None
    if not label.strip():
        return default
    modifiers = [_MODIFIERS.get(piece.strip().upper()) for piece in label.split("+")]
    return sum(modifiers) if None not in modifiers and len(set(modifiers)) == len(modifiers) else None


def trigger_key(rule: dict):
    trigger = rule.get("trigger") or "hotkey"
    if trigger == "hotkey":
        key = parse_shortcut(rule.get("shortcut"))
        return (trigger, *key) if key else None
    if trigger == "mouseButton":
        mask, button = _mouse_modifiers(rule, 0), rule.get("mouseButton")
        return (trigger, mask, button) if mask is not None and type(button) is int and button in {2, 3, 4} else None
    if trigger == "gesture":
        mask, direction = _mouse_modifiers(rule, ALT), rule.get("direction")
        return (trigger, mask, direction) if mask is not None and mask & ALT and direction in ("left", "right", "up", "down") else None
    return None


@dataclass(frozen=True)
class Binding:
    identifier: str
    action: str
    key: tuple
    include: frozenset[str]
    exclude: frozenset[str]

    @classmethod
    def from_rule(cls, rule: dict) -> Binding | None:
        key, action = trigger_key(rule), rule.get("actionID")
        if key is None or not isinstance(action, str) or not action:
            return None
        application = rule.get("application") or rule.get("appBundleID")
        if application and (not isinstance(application, str) or not _application(application)):
            return None
        for field in ("include", "exclude"):
            value = rule.get(field, [])
            if not isinstance(value, list) or not all(isinstance(item, str) and _application(item) for item in value):
                return None
        scopes = _scope([application]) if application else _scope(rule.get("include"))
        return cls(str(rule.get("id") or ""), action, key, scopes, _scope(rule.get("exclude")))

    def matches(self, application: str) -> bool:
        application = application.casefold()
        return (not self.include or application in self.include) and application not in self.exclude


def direction_between(start: tuple[int, int], finish: tuple[int, int]) -> str | None:
    dx, dy = finish[0] - start[0], finish[1] - start[1]
    if hypot(dx, dy) < 70:
        return None
    if abs(dx) > abs(dy) * 1.4:
        return "right" if dx > 0 else "left"
    if abs(dy) > abs(dx) * 1.4:
        return "down" if dy > 0 else "up"
    return None
