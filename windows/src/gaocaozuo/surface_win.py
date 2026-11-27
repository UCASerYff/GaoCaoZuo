"""Shared appearance for the app-owned Windows dialogs and overlays."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass

from gaocaozuo.native_win import bind, user
from gaocaozuo.resources import asset_dir


@dataclass(frozen=True)
class SurfaceColors:
    background: str
    surface: str
    ink: str
    subtle: str
    border: str
    accent: str
    on_accent: str
    selected: str
    selected_ink: str


LIGHT = SurfaceColors("#f3f6fa", "#ffffff", "#16253b", "#44586e", "#aab9c9", "#245a99", "#ffffff", "#deecff", "#153960")
DARK = SurfaceColors("#111a26", "#192535", "#e8f0fb", "#b7c7db", "#53677e", "#a3caff", "#11243d", "#284d76", "#f1f6ff")
_appearance = ContextVar("windows_surface_appearance", default="system")


@contextmanager
def native_surface(setting):
    token = _appearance.set(setting)
    try:
        yield
    finally:
        _appearance.reset(token)


def surface_colors(setting=None):
    setting = _appearance.get() if setting is None else setting
    if os.name == "nt":
        system_colors = _high_contrast_colors()
        if system_colors:
            return system_colors
    if setting == "system" and os.name == "nt":
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
                setting = "light" if winreg.QueryValueEx(key, "AppsUseLightTheme")[0] else "dark"
        except OSError:
            pass
    return DARK if setting == "dark" else LIGHT


def _high_contrast_colors():
    class HighContrast(c.Structure):
        _fields_ = [("size", w.UINT), ("flags", w.DWORD), ("scheme", w.LPWSTR)]

    contrast = HighContrast(c.sizeof(HighContrast))
    query = user("SystemParametersInfoW", w.BOOL, w.UINT, w.UINT, w.LPVOID, w.UINT)
    if not query(0x0042, contrast.size, c.byref(contrast), 0) or not contrast.flags & 1:
        return None
    color = user("GetSysColor", w.DWORD, c.c_int)

    def text(index):
        value = color(index)
        return f"#{value & 255:02x}{(value >> 8) & 255:02x}{(value >> 16) & 255:02x}"

    return SurfaceColors(text(15), text(5), text(8), text(8), text(8), text(13), text(14), text(13), text(14))


def hwnd_for(widget):
    identifier = widget.winfo_id()
    return user("GetParent", w.HWND, w.HWND)(identifier) or identifier


def window_dpi(hwnd):
    try:
        return user("GetDpiForWindow", w.UINT, w.HWND)(hwnd) or 96
    except AttributeError:
        return 96


def pointer_work_area():
    class MonitorInfo(c.Structure):
        _fields_ = [("size", w.DWORD), ("monitor", w.RECT), ("work", w.RECT), ("flags", w.DWORD)]

    point = w.POINT()
    if not user("GetCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(point)):
        return None
    monitor = user("MonitorFromPoint", w.HANDLE, w.POINT, w.DWORD)(point, 2)
    info = MonitorInfo(size=c.sizeof(MonitorInfo))
    if user("GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(MonitorInfo))(monitor, c.byref(info)):
        return info.work
    return None


def set_window_chrome(root, colors):
    import tkinter as tk

    if colors in (LIGHT, DARK):
        hwnd = hwnd_for(root)
        dark = w.BOOL(colors == DARK)
        attribute = bind("dwmapi", "DwmSetWindowAttribute", c.c_long, w.HWND, w.DWORD, w.LPVOID, w.DWORD)
        if attribute(hwnd, 20, c.byref(dark), c.sizeof(dark)) != 0:
            attribute(hwnd, 19, c.byref(dark), c.sizeof(dark))
    assets = asset_dir()
    icon = assets / "operation-icon.png"
    if not icon.is_file() and len(assets.parents) > 3:
        icon = assets.parents[3] / "Assets" / "AppIcon.png"
    if icon.is_file():
        try:
            root.iconphoto(True, tk.PhotoImage(master=root, file=str(icon)).subsample(16))
        except tk.TclError:
            pass


class TkSurface:
    def __init__(self, root, colors, dpi=None):
        from tkinter import font, ttk

        self.colors = colors
        self.scale = (dpi or window_dpi(hwnd_for(root))) / 96
        installed = {name.casefold(): name for name in font.families(root)}
        self.family = next((installed[name] for name in ("microsoft yahei ui", "segoe ui") if name in installed), "TkDefaultFont")
        style = ttk.Style(root)
        style.theme_use("clam")
        for variant, background, foreground in (("Action", colors.accent, colors.on_accent),
                                                ("Secondary", colors.surface, colors.ink)):
            key = f"{variant}.TButton"
            style.configure(key, font=self.font(14, "bold" if variant == "Action" else "normal"),
                            padding=(self.px(14), self.px(7)), background=background,
                            foreground=foreground, bordercolor=colors.border, focuscolor=foreground,
                            lightcolor=background, darkcolor=background)
            style.map(key, background=[("disabled", colors.background), ("active", colors.selected)],
                      foreground=[("disabled", colors.subtle), ("active", colors.selected_ink)],
                      bordercolor=[("focus", colors.accent)])
        for orient in ("Vertical", "Horizontal"):
            style.configure(f"{orient}.TScrollbar", background=colors.border, troughcolor=colors.background,
                            bordercolor=colors.surface, arrowcolor=colors.ink, width=self.px(13))

    def px(self, pixels):
        return max(1, round(pixels * self.scale))

    def font(self, pixels, weight="normal"):
        return self.family, -self.px(pixels), weight
