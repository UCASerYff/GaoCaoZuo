"""Inspect synthetic native surfaces on a separate Windows desktop without switching to it."""

from __future__ import annotations

import argparse
import ctypes as c
import ctypes.wintypes as w
import json
import os
import sys
import tkinter as tk
import uuid
from pathlib import Path
from unittest.mock import patch

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from gaocaozuo import capture_win
from gaocaozuo.capture_win import BitmapInfo, _pin_surface, _source_picker
from gaocaozuo.desktop_win import physical_coordinates
from gaocaozuo.localization import native_locale
from gaocaozuo.native_win import bind, is_input_desktop, kernel, user
from gaocaozuo.runtime_win import _IdleWarning
from gaocaozuo.surface_win import DARK, LIGHT, native_surface, window_dpi


def widgets(parent):
    for widget in parent.winfo_children():
        yield widget
        yield from widgets(widget)


def inspect_tk(root, dpi):
    root.update()
    sizes = {}
    for widget in widgets(root):
        if widget.winfo_class() not in {"Label", "TButton", "Listbox"}:
            continue
        key = widget.winfo_class()
        sizes[key] = sizes.get(key, 0) + 1
        if key == "Listbox" or widget.cget("text"):
            measured = key, widget.winfo_width(), widget.winfo_reqwidth(), widget.winfo_height(), widget.winfo_reqheight()
            assert widget.winfo_width() >= min(widget.winfo_reqwidth(), root.winfo_width() * .85), measured
            assert widget.winfo_height() >= min(widget.winfo_reqheight(), round(15 * dpi / 96)), measured
    assert sizes.get("Label") and sizes.get("TButton"), sizes
    return sizes


def paint(hwnd, msg, flags):
    pid = w.DWORD()
    user("GetWindowThreadProcessId", w.DWORD, w.HWND, w.LPDWORD)(hwnd, c.byref(pid))
    assert pid.value == os.getpid() and not is_input_desktop(), "The capture window is limited to this private test desktop."
    area = w.RECT()
    user("GetClientRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(area))
    width, height = area.right, area.bottom
    assert 100 <= width <= 1600 and 60 <= height <= 1200, (width, height)
    memory = bind("gdi32", "CreateCompatibleDC", w.HDC, w.HDC)(None)
    data = c.c_void_p()
    info = BitmapInfo(size=40, width=width, height=-height, planes=1, bits=32)
    bitmap = bind("gdi32", "CreateDIBSection", w.HBITMAP, w.HDC, c.POINTER(BitmapInfo), w.UINT,
                  c.POINTER(c.c_void_p), w.HANDLE, w.DWORD)(memory, c.byref(info), 0, c.byref(data), None, 0)
    assert memory and bitmap and data
    select = bind("gdi32", "SelectObject", w.HANDLE, w.HDC, w.HANDLE)
    previous = select(memory, bitmap)
    try:
        c.memset(data, 0, width * height * 4)
        user("SendMessageW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, msg, memory, flags)
        bind("gdi32", "GdiFlush", w.BOOL)()
        return Image.frombytes("RGB", (width, height), c.string_at(data, width * height * 4), "raw", "BGRX")
    finally:
        select(memory, previous)
        bind("gdi32", "DeleteObject", w.BOOL, w.HANDLE)(bitmap)
        bind("gdi32", "DeleteDC", w.BOOL, w.HDC)(memory)


def test_picker(folder, scheme, dpi):
    root = tk.Tk()
    root.withdraw()
    try:
        with native_locale("zh-Hans"), native_surface(scheme):
            result = _source_picker(root, "多窗口合成", "按住 Ctrl 或 Shift 选择多个窗口",
                                    ["合成截图演示窗口", "无真实资料的本机文本编辑器", "A" * 120], True, dpi)
        assert result == []
        root.geometry(f"{round(344*dpi/96)}x{round(290*dpi/96)}")
        root.deiconify()
        layout = inspect_tk(root, dpi)
        screenshot = paint(root.winfo_id(), 0x0317, 0x14)  # WM_PRINT | PRF_CLIENT | PRF_CHILDREN
        if screenshot.getbbox():
            screenshot.save(folder / f"native-picker-{scheme}-{dpi}.png")
        options = next(widget for widget in widgets(root) if widget.winfo_class() == "Listbox")
        action = next(widget for widget in widgets(root) if widget.winfo_class() == "TButton" and widget.cget("text") == "选择")
        assert action.instate(["disabled"])
        options.selection_set(0, 1)
        options.event_generate("<<ListboxSelect>>")
        assert action.instate(["!disabled"])
        action.invoke()
        assert result == [0, 1]
        return {"windows": layout, "captured": bool(screenshot.getbbox()), "selected": result}
    finally:
        root.destroy()


def test_pin(folder, scheme, dpi):
    root = tk.Tk()
    root.withdraw()
    try:
        fixture = Image.new("RGB", (576, 290), "#dceaf9")
        draw = ImageDraw.Draw(fixture)
        draw.rounded_rectangle((20, 20, 556, 270), radius=17, fill="#ffffff", outline="#a9c2df", width=2)
        for x, width in ((48, 96), (167, 138), (331, 177)):
            draw.rounded_rectangle((x, 60, x + width, 105), radius=8, fill="#245a99")
            for y in (129, 155, 181, 207):
                draw.line((x, y, x + width - 12, y), fill="#9bafc9", width=3)
        _pin_surface(root, fixture, "搞操作 · 贴图", "关闭", DARK if scheme == "dark" else LIGHT, dpi)
        root.deiconify()
        layout = inspect_tk(root, dpi)
        screenshot = paint(root.winfo_id(), 0x0317, 0x14)
        if screenshot.getbbox():
            screenshot.save(folder / f"native-pin-{scheme}-{dpi}.png")
        picture = next(widget for widget in widgets(root) if widget.winfo_class() == "Label" and widget.cget("image"))
        original = picture.image.width()
        root.geometry(f"{round(296*dpi/96)}x{round(225*dpi/96)}")
        root.after(110, root.quit)
        root.mainloop()
        assert picture.image.width() < original
        return {"windows": layout, "captured": bool(screenshot.getbbox()), "pinResize": [original, picture.image.width()]}
    finally:
        root.destroy()


def test_warning(folder, scheme):
    warning = _IdleWarning(lambda: "zh-Hans", lambda: scheme)
    try:
        assert warning.update(("lockScreen", 12))
        assert warning.update(("lockScreen", 11))
        assert warning.subclass is not None
        ex_style = user("GetWindowLongPtrW", c.c_ssize_t, w.HWND, c.c_int)(warning.hwnd, -20)
        assert ex_style & 0x08000000  # WS_EX_NOACTIVATE
        with physical_coordinates():
            screenshot = paint(warning.hwnd, 0x0318, 0x04)  # WM_PRINTCLIENT | PRF_CLIENT
        assert screenshot.getbbox() and len(screenshot.getcolors(65536)) > 10
        screenshot.save(folder / f"native-idle-warning-{scheme}.png")
        return {"visible": True, "nonactivating": True, "captured": True, "dpi": window_dpi(warning.hwnd)}
    finally:
        warning.update(None)
        assert not warning.hwnd


def test_region_geometry():
    make_root = tk.Tk

    def confinement():
        assert not is_input_desktop()

    def scripted_tk():
        root = make_root()

        def dispatch_events():
            root.update()
            canvas = next(widget for widget in root.winfo_children() if isinstance(widget, tk.Canvas))
            tip = next(widget for widget in root.winfo_children() if isinstance(widget, tk.Toplevel))
            hint = next(iter(tip.winfo_children()))
            canvas.event_generate("<ButtonPress-1>", x=18, y=22, rootx=18, rooty=22)
            canvas.event_generate("<B1-Motion>", x=314, y=217, rootx=314, rooty=217)
            root.update()
            assert any(widget.cget("text") == "296 × 195 px" for widget in hint.winfo_children())
            canvas.event_generate("<ButtonRelease-1>", x=314, y=217, rootx=314, rooty=217)

        root.mainloop = dispatch_events
        return root

    with patch.object(tk, "Tk", scripted_tk), patch.object(capture_win, "_interactive", confinement), \
            patch.object(capture_win, "desktop_bounds", return_value=(0, 0, 800, 600)):
        selected = capture_win.choose_region()
    assert selected == (18, 22, 314, 217), selected
    return {"syntheticRegion": selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    thread = kernel("GetCurrentThreadId", w.DWORD)()
    initial = user("GetThreadDesktop", w.HANDLE, w.DWORD)(thread)
    desktop = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)(
        "GaoUIReview-" + uuid.uuid4().hex, None, None, 0, 0x000F01FF, None)
    if not desktop:
        raise c.WinError(c.get_last_error())
    select = user("SetThreadDesktop", w.BOOL, w.HANDLE)
    try:
        assert select(desktop) and not is_input_desktop()
        states = {}
        for scheme, dpi in (("light", 96), ("dark", 144)):
            states[scheme] = {"dpi": dpi, "picker": test_picker(output, scheme, dpi),
                              "pin": test_pin(output, scheme, dpi), "warning": test_warning(output, scheme)}
        states["region"] = test_region_geometry()
        print(json.dumps(states, ensure_ascii=False))
    finally:
        select(initial)
        user("CloseDesktop", w.BOOL, w.HANDLE)(desktop)


if __name__ == "__main__":
    main()
