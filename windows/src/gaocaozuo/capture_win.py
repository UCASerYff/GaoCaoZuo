"""Explicit Windows capture and native selection/pin windows."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
import threading
from dataclasses import dataclass

from PIL import Image, ImageGrab, ImageTk

from gaocaozuo.desktop_win import WindowIdentity, _identity, physical_coordinates
from gaocaozuo.errors import AppError
from gaocaozuo.localization import native_text
from gaocaozuo.native_win import bind, is_input_desktop, user

MAX_PIXELS = 48_000_000


def _interactive() -> None:
    if os.name != "nt" or not is_input_desktop():
        raise AppError("当前 Windows 桌面不可采集。请返回普通桌面后重试。", "unavailable")


def desktop_bounds() -> tuple[int, int, int, int]:
    metric = user("GetSystemMetrics", c.c_int, c.c_int)
    x, y, width, height = (metric(i) for i in (76, 77, 78, 79))
    return x, y, x + width, y + height


def _monitor_bounds() -> tuple[int, int, int, int]:
    class MonitorInfo(c.Structure):
        _fields_ = [("size", w.DWORD), ("monitor", w.RECT), ("work", w.RECT), ("flags", w.DWORD), ("device", w.WCHAR * 32)]

    displays = []
    callback = c.WINFUNCTYPE(w.BOOL, w.HANDLE, w.HDC, c.POINTER(w.RECT), w.LPARAM)

    @callback
    def add(monitor, _dc, _bounds, _argument):
        info = MonitorInfo(size=c.sizeof(MonitorInfo))
        if user("GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(MonitorInfo))(monitor, c.byref(info)):
            box = info.monitor
            displays.append((info.device.split("\\")[-1], bool(info.flags & 1), (box.left, box.top, box.right, box.bottom)))
        return True

    user("EnumDisplayMonitors", w.BOOL, w.HDC, c.POINTER(w.RECT), callback, w.LPARAM)(None, None, add, 0)
    if not displays:
        raise AppError("无法读取当前屏幕。", "rejected")
    if len(displays) == 1:
        return displays[0][2]
    main_screen = " · " + native_text("主屏幕")
    labels = [f"{name}{main_screen if primary else ''} · {box[2]-box[0]} × {box[3]-box[1]}" for name, primary, box in displays]
    return displays[_pick_sources("选择屏幕截图", "选择要截图的屏幕", labels)[0]][2]


def check_bounds(bounds: tuple[int, int, int, int]) -> tuple[int, int]:
    left, top, right, bottom = bounds
    width, height = right - left, bottom - top
    if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
        raise AppError("所选画面尺寸无效或超过 4800 万像素。", "invalid")
    return width, height


def choose_region(single_point=False) -> tuple[int, int, int, int]:
    import tkinter as tk

    _interactive()
    with physical_coordinates():
        left, top, right, bottom = desktop_bounds()
        check_bounds((left, top, right, bottom))
        window = tk.Tk()
        selected = []
        start = []
        try:
            window.overrideredirect(True)
            window.attributes("-topmost", True, "-alpha", 0.28)
            window.geometry(f"{right-left}x{bottom-top}+0+0")
            canvas = tk.Canvas(window, bg="#101018", cursor="crosshair", highlightthickness=0)
            canvas.pack(fill="both", expand=True)
            instruction = native_text("点击要取色的像素，Esc 取消" if single_point else "拖动选择截图区域，Esc 取消")
            canvas.create_text(30, 25, text=instruction, anchor="nw", fill="white", font=("Microsoft YaHei UI", 16))
            mark = canvas.create_rectangle(0, 0, 0, 0, outline="#7dbdff", width=4, fill="#85bbf4")

            def begin(event):
                start[:] = [event.x, event.y]

            def update(event):
                if start:
                    canvas.coords(mark, *start, event.x, event.y)

            def finish(event):
                if not start:
                    return
                if single_point:
                    x, y = left + event.x, top + event.y
                    selected.append((x, y, x + 1, y + 1))
                    window.quit()
                    return
                x0, x1 = sorted((start[0], event.x))
                y0, y1 = sorted((start[1], event.y))
                if x1 - x0 >= 4 and y1 - y0 >= 4:
                    selected.append((left + x0, top + y0, left + x1, top + y1))
                    window.quit()

            canvas.bind("<Button-1>", begin)
            canvas.bind("<B1-Motion>", update)
            canvas.bind("<ButtonRelease-1>", finish)
            window.bind("<Escape>", lambda _event: window.quit())
            window.after(90_000, window.quit)
            window.update_idletasks()
            frame = user("GetParent", w.HWND, w.HWND)(window.winfo_id()) or window.winfo_id()
            user("SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT)(
                frame, w.HWND(-1), left, top, right - left, bottom - top, 0x0040
            )
            window.focus_force()
            window.mainloop()
        finally:
            window.destroy()
    if not selected:
        raise AppError("已取消选择区域。", "cancelled")
    _flush_desktop()
    return selected[0]


def _flush_desktop() -> None:
    bind("dwmapi", "DwmFlush", c.c_long)()


def window_at_center(bounds: tuple[int, int, int, int]) -> int:
    left, top, right, bottom = bounds
    with physical_coordinates():
        return _root_at((left + right) // 2, (top + bottom) // 2)


def _root_at(x: int, y: int) -> int:
    return _root_window(_window_at(x, y))


def _window_at(x: int, y: int) -> int:
    return int(user("WindowFromPoint", w.HWND, w.POINT)(w.POINT(x, y)) or 0)


def _root_window(hwnd: int) -> int:
    return int(user("GetAncestor", w.HWND, w.HWND, w.UINT)(hwnd, 2) or hwnd or 0)


def region_has_target(bounds: tuple[int, int, int, int], hwnd: int) -> bool:
    if not hwnd:
        return False
    with physical_coordinates():
        x0, y0, x1, y1 = bounds
        box = w.RECT()
        if not user("GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(box)):
            return False
        if not box.left <= x0 < x1 <= box.right or not box.top <= y0 < y1 <= box.bottom:
            return False
        return all(_root_at(x, y) == hwnd for x in (x0, (x0 + x1) // 2, x1 - 1) for y in (y0, (y0 + y1) // 2, y1 - 1))


def window_identity(hwnd: int) -> WindowIdentity | None:
    return _identity(hwnd)


def window_frame(hwnd: int) -> tuple[int, int, int, int] | None:
    if os.name != "nt":
        return None
    with physical_coordinates():
        box = w.RECT()
        if user("GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(box)):
            return box.left, box.top, box.right, box.bottom
    return None


def foreground_window() -> int:
    return int(user("GetForegroundWindow", w.HWND)() or 0)


@dataclass(frozen=True)
class ScrollAnchor:
    point: tuple[int, int]
    receiver: WindowIdentity


def _visible_region(bounds: tuple[int, int, int, int], hwnd: int) -> bool:
    if not region_has_target(bounds, hwnd):
        return False
    x0, y0, x1, y1 = bounds
    get_window = user("GetWindow", w.HWND, w.HWND, w.UINT)
    visible = user("IsWindowVisible", w.BOOL, w.HWND)
    minimized = user("IsIconic", w.BOOL, w.HWND)
    attribute = bind("dwmapi", "DwmGetWindowAttribute", c.c_long, w.HWND, w.DWORD, w.LPVOID, w.DWORD)
    other = get_window(hwnd, 3)  # GW_HWNDPREV, the windows above the target in Z order.
    visited = {hwnd}
    while other and other not in visited and len(visited) < 4096:
        visited.add(other)
        if visible(other) and not minimized(other):
            cloaked = w.DWORD()
            if attribute(other, 14, c.byref(cloaked), c.sizeof(cloaked)) or not cloaked.value:
                frame = window_frame(other)
                if frame is None:
                    return False
                left, top, right, bottom = frame
                if max(x0, left) < min(x1, right) and max(y0, top) < min(y1, bottom):
                    return False
        other = get_window(other, 3)
    return not other


def verify_scroll_anchor(bounds, identity: WindowIdentity, frame, anchor: ScrollAnchor | None = None) -> ScrollAnchor:
    _interactive()
    hwnd = identity.hwnd
    with physical_coordinates():
        if identity.pid == os.getpid():
            raise AppError("请选择外部窗口中的滚动区域。", "scrollUnavailable")
        if foreground_window() != hwnd or window_identity(hwnd) != identity or window_frame(hwnd) != frame or not _visible_region(bounds, hwnd):
            raise AppError("目标窗口已改变、移动或被遮挡。请返回原窗口后手动续拍。", "targetChanged")
        affinity = w.DWORD()
        if user("GetWindowDisplayAffinity", w.BOOL, w.HWND, w.LPDWORD)(hwnd, c.byref(affinity)) and affinity.value:
            raise AppError("目标窗口启用了 Windows 内容捕获保护。", "unavailable")
        pointer = w.POINT()
        x0, y0, x1, y1 = bounds
        if not user("GetPhysicalCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(pointer)) or not (
            x0 <= pointer.x < x1 and y0 <= pointer.y < y1
        ):
            raise AppError("鼠标不在选区内，已停止自动滚动。", "pointerLeft")
        point = pointer.x, pointer.y
        if anchor is not None and point != anchor.point:
            raise AppError("鼠标已移动，已停止自动滚动。", "pointerLeft")
        get_key = user("GetAsyncKeyState", c.c_short, c.c_int)
        if any(get_key(key) & 0x8000 for key in (1, 2, 4, 5, 6, 0x10, 0x11, 0x12, 0x1B, 0x5B, 0x5C)):
            raise AppError("检测到鼠标按键、修饰键或 Esc，已停止自动滚动。", "inputHeld")
        receiver = window_identity(_window_at(*point))
        if receiver is None or receiver.pid != identity.pid or _root_window(receiver.hwnd) != hwnd:
            raise AppError("无法核验选区内的滚动控件，请改用手动续拍。", "targetChanged")
        if anchor is not None and receiver != anchor.receiver:
            raise AppError("指针下的滚动控件已改变，请改用手动续拍。", "targetChanged")
        return ScrollAnchor(point, receiver)


def _send_scroll_notch(receiver: int, point: tuple[int, int]) -> bool:
    # WM_MOUSEWHEEL carries signed screen coordinates in two 16-bit fields.
    if not receiver or not all(-32768 <= value <= 32767 for value in point):
        return False
    x, y = point
    coordinates = ((y & 0xFFFF) << 16) | (x & 0xFFFF)
    if coordinates >= 0x80000000:
        coordinates -= 0x100000000
    send = user("SendMessageTimeoutW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM, w.UINT, w.UINT,
                c.POINTER(c.c_size_t))
    result = c.c_size_t()
    return bool(send(receiver, 0x020A, (-120 & 0xFFFF) << 16, coordinates, 0x0023, 320, c.byref(result)))


def scroll_down(bounds, identity: WindowIdentity, frame, anchor: ScrollAnchor) -> None:
    verify_scroll_anchor(bounds, identity, frame, anchor)
    point = w.POINT(*anchor.point)
    convert = user("PhysicalToLogicalPointForPerMonitorDPI", w.BOOL, w.HWND, c.POINTER(w.POINT))
    if not convert(anchor.receiver.hwnd, c.byref(point)):
        raise AppError("无法换算目标窗口的滚动坐标，请改用手动续拍。", "scrollUnavailable")
    if foreground_window() != identity.hwnd or window_identity(anchor.receiver.hwnd) != anchor.receiver:
        raise AppError("发送滚动前目标窗口已改变。", "targetChanged")
    if not _send_scroll_notch(anchor.receiver.hwnd, (point.x, point.y)):
        raise AppError("目标窗口未确认处理滚动请求。请检查当前画面后手动续拍。", "scrollUnavailable")


def _pick_sources(title: str, message: str, labels: list[str], multi=False) -> tuple[int, ...]:
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    result = []
    try:
        root.title(native_text(title))
        root.attributes("-topmost", True)
        root.geometry("560x400")
        ttk.Label(root, text=native_text(message), wraplength=525).pack(anchor="w", padx=15, pady=12)
        options = tk.Listbox(root, exportselection=False, activestyle="dotbox", selectmode="extended" if multi else "browse")
        options.pack(fill="both", expand=True, padx=15)
        for label in labels:
            options.insert("end", label)

        def select(_event=None):
            indices = options.curselection()
            if indices:
                result.extend(indices)
                root.quit()

        if not multi:
            options.bind("<Double-Button-1>", select)
            options.selection_set(0)
        options.bind("<Return>", select)
        ttk.Button(root, text=native_text("选择"), command=select).pack(pady=12)
        root.bind("<Escape>", lambda _event: root.quit())
        root.protocol("WM_DELETE_WINDOW", root.quit)
        root.after(90_000, root.quit)
        options.focus_set()
        root.mainloop()
    finally:
        root.destroy()
    if not result:
        raise AppError("已取消选择截图来源。", "cancelled")
    _flush_desktop()
    return tuple(result)


def choose_windows(multi=False) -> list[int]:
    from gaocaozuo.platform_win import list_windows

    windows = [item for item in list_windows() if item.get("width", 0) > 0 and item.get("height", 0) > 0]
    if not windows:
        raise AppError("没有可供选择的窗口。", "missing")
    title = "多窗口合成" if multi else "选择窗口截图"
    message = "按住 Ctrl 或 Shift 选择多个窗口" if multi else "选择要截图的窗口"
    return [windows[index]["hwnd"] for index in _pick_sources(title, message, [row["title"] for row in windows], multi)]


def sample_color() -> dict:
    _interactive()
    with physical_coordinates():
        x, y, _, _ = choose_region(single_point=True)
        desktop = user("GetDC", w.HDC, w.HWND)(None)
        if not desktop:
            raise AppError("Windows 未返回所选像素。", "rejected")
        try:
            pixel = bind("gdi32", "GetPixel", w.DWORD, w.HDC, c.c_int, c.c_int)(desktop, x, y)
        finally:
            user("ReleaseDC", c.c_int, w.HWND, w.HDC)(None, desktop)
    if pixel == 0xFFFFFFFF:
        raise AppError("Windows 未返回所选像素。", "rejected")
    rgb = [pixel & 0xFF, (pixel >> 8) & 0xFF, (pixel >> 16) & 0xFF]
    return {"hex": "#" + "".join(f"{channel:02X}" for channel in rgb), "rgb": rgb, "colorSpace": "sRGB"}


def capture(mode: str, bounds=None, hwnd: int | None = None) -> Image.Image:
    _interactive()
    with physical_coordinates():
        if mode == "window":
            return _capture_window(hwnd or choose_windows()[0])
        if mode == "windows":
            selected = hwnd if isinstance(hwnd, list) else choose_windows(multi=True)
            return _capture_windows(selected)
        if mode == "region":
            bounds = bounds or choose_region()
        elif mode == "display":
            bounds = _monitor_bounds()
        elif mode == "virtual":
            bounds = desktop_bounds()
        else:
            raise AppError("未知的截图来源。", "invalid")
        check_bounds(bounds)
        left, top, right, bottom = desktop_bounds()
        x0, y0, x1, y1 = bounds
        if x0 < left or y0 < top or x1 > right or y1 > bottom:
            raise AppError("区域已移出当前桌面。", "rejected")
        try:
            return ImageGrab.grab(bbox=bounds, all_screens=True, include_layered_windows=True)
        except OSError as exc:
            raise AppError("Windows 未返回屏幕画面。", "rejected") from exc


class BitmapInfo(c.Structure):
    _fields_ = [
        ("size", w.DWORD), ("width", w.LONG), ("height", w.LONG), ("planes", w.WORD), ("bits", w.WORD),
        ("compression", w.DWORD), ("imageSize", w.DWORD), ("xPels", w.LONG), ("yPels", w.LONG),
        ("colors", w.DWORD), ("important", w.DWORD), ("firstColor", w.DWORD),
    ]


def _capture_window(hwnd: int) -> Image.Image:
    box = w.RECT()
    if not user("IsWindowVisible", w.BOOL, w.HWND)(hwnd) or user("IsIconic", w.BOOL, w.HWND)(hwnd):
        raise AppError("所选窗口已关闭、隐藏或最小化。", "missing")
    if user("IsHungAppWindow", w.BOOL, w.HWND)(hwnd) or not user("GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))(hwnd, c.byref(box)):
        raise AppError("无法读取所选窗口的边界。", "rejected")
    affinity = w.DWORD()
    if user("GetWindowDisplayAffinity", w.BOOL, w.HWND, w.LPDWORD)(hwnd, c.byref(affinity)) and affinity.value:
        raise AppError("所选窗口设置了 Windows 内容捕获保护。", "rejected")
    width, height = check_bounds((box.left, box.top, box.right, box.bottom))
    desktop = user("GetDC", w.HDC, w.HWND)(None)
    memory = bitmap = previous = None
    try:
        if desktop:
            memory = bind("gdi32", "CreateCompatibleDC", w.HDC, w.HDC)(desktop)
        data = c.c_void_p()
        info = BitmapInfo(size=40, width=width, height=-height, planes=1, bits=32)
        if memory:
            make_bitmap = bind("gdi32", "CreateDIBSection", w.HBITMAP, w.HDC, c.POINTER(BitmapInfo), w.UINT,
                               c.POINTER(c.c_void_p), w.HANDLE, w.DWORD)
            bitmap = make_bitmap(memory, c.byref(info), 0, c.byref(data), None, 0)
        if not (desktop and memory and bitmap and data):
            raise AppError("无法为所选窗口分配画面缓冲区。", "rejected")
        c.memset(data, 0, width * height * 4)
        select = bind("gdi32", "SelectObject", w.HANDLE, w.HDC, w.HANDLE)
        previous = select(memory, bitmap)
        if not previous or not user("PrintWindow", w.BOOL, w.HWND, w.HDC, w.UINT)(hwnd, memory, 0):
            raise AppError("所选应用没有提供窗口画面。", "rejected")
        if not bind("gdi32", "GdiFlush", w.BOOL)():
            raise AppError("Windows 未返回完整窗口画面。", "rejected")
        image = Image.frombytes("RGB", (width, height), c.string_at(data, width * height * 4), "raw", "BGRX")
        if image.getbbox() is None:
            raise AppError("所选窗口返回全黑画面，可能由应用捕获限制导致。", "rejected")
        visible = w.RECT()
        if _extended_bounds(hwnd, visible):
            crop = (visible.left - box.left, visible.top - box.top, visible.right - box.left, visible.bottom - box.top)
            if 0 <= crop[0] < crop[2] <= width and 0 <= crop[1] < crop[3] <= height:
                image = image.crop(crop)
        return image
    finally:
        if previous:
            select(memory, previous)
        if bitmap:
            bind("gdi32", "DeleteObject", w.BOOL, w.HANDLE)(bitmap)
        if memory:
            bind("gdi32", "DeleteDC", w.BOOL, w.HDC)(memory)
        if desktop:
            user("ReleaseDC", c.c_int, w.HWND, w.HDC)(None, desktop)


def _extended_bounds(hwnd: int, box: w.RECT) -> bool:
    get = bind("dwmapi", "DwmGetWindowAttribute", c.c_long, w.HWND, w.DWORD, w.LPVOID, w.DWORD)
    return get(hwnd, 9, c.byref(box), c.sizeof(box)) == 0


def _capture_windows(handles: list[int]) -> Image.Image:
    if not 1 <= len(handles) <= 24 or not all(type(value) is int and value > 0 for value in handles) or len(set(handles)) != len(handles):
        raise AppError("请选择 1 至 24 个不同的窗口。", "invalid")
    locations = []
    for hwnd in handles:
        box = w.RECT()
        if not _extended_bounds(hwnd, box):
            raise AppError("所选窗口已变化或无法读取其边界。", "rejected")
        locations.append((box.left, box.top, box.right, box.bottom))
    left, top = min(box[0] for box in locations), min(box[1] for box in locations)
    width, height = check_bounds((left, top, max(box[2] for box in locations), max(box[3] for box in locations)))
    output = Image.new("RGB", (width, height), "#ececf0")
    for hwnd, (x, y, right, bottom) in reversed(list(zip(handles, locations))):
        tile = _capture_window(hwnd)
        if tile.size != (right - x, bottom - y):
            raise AppError("所选窗口大小在合成时发生变化。", "rejected")
        output.paste(tile, (x - left, y - top))
    return output


def show_pin(image: Image.Image) -> None:
    import tkinter as tk

    _interactive()
    result = []
    ready = threading.Event()
    title = "搞操作 · " + native_text("贴图")

    def display():
        try:
            with physical_coordinates():
                root = tk.Tk()
                root.title(title)
                root.attributes("-topmost", True)
                preview = image.copy()
                preview.thumbnail((int(root.winfo_screenwidth() * 0.75), int(root.winfo_screenheight() * 0.70)))
                photo = ImageTk.PhotoImage(preview, master=root)
                tk.Label(root, image=photo, borderwidth=0).pack()
                root.bind("<Escape>", lambda _event: root.destroy())
                root.update_idletasks()
                result.append(True)
                ready.set()
                root.mainloop()
                del photo
        except (RuntimeError, tk.TclError):
            ready.set()

    threading.Thread(target=display, name="gaocaozuo-pin", daemon=True).start()
    if not ready.wait(5) or not result:
        raise AppError("未能打开置顶贴图窗口。", "rejected")
