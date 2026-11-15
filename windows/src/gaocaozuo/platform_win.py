"""只在 Windows 上调用系统接口。其他系统返回明确失败。"""

from __future__ import annotations

import os
import sys

from gaocaozuo.errors import AppError


def _windll():
    if os.name != "nt":
        raise AppError("当前不是 Windows。", "unavailable")
    import ctypes

    return ctypes


def lock_workstation() -> bool:
    ctypes = _windll()
    return bool(ctypes.windll.user32.LockWorkStation())


def start_screensaver() -> bool:
    ctypes = _windll()
    HWND_BROADCAST = 0xFFFF
    WM_SYSCOMMAND = 0x0112
    SC_SCREENSAVE = 0xF140
    ctypes.windll.user32.SendMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_SCREENSAVE, 0)
    return True


def suspend() -> bool:
    ctypes = _windll()
    # 不强制关闭唤醒唤醒，也不改电源策略。返回值只说明调用是否被接受。
    return bool(ctypes.windll.powrprof.SetSuspendState(False, False, False))


def execution_state(awake: bool) -> bool:
    ctypes = _windll()
    ES_CONTINUOUS = 0x80000000
    ES_SYSTEM_REQUIRED = 0x00000001
    ES_DISPLAY_REQUIRED = 0x00000002
    flags = ES_CONTINUOUS | (ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED if awake else 0)
    result = ctypes.windll.kernel32.SetThreadExecutionState(flags)
    return result != 0


_MEDIA = {
    "volumeUp": 0xAF,
    "volumeDown": 0xAE,
    "mute": 0xAD,
    "nextTrack": 0xB0,
    "previousTrack": 0xB1,
    "playPause": 0xB3,
}


def media_key(name: str) -> bool:
    if name not in _MEDIA:
        raise AppError("这个系统动作在 Windows 上没有对应媒体键。", "unavailable")
    ctypes = _windll()
    vk = _MEDIA[name]
    ctypes.windll.user32.keybd_event(vk, 0, 0, 0)
    ctypes.windll.user32.keybd_event(vk, 0, 2, 0)
    return True


def set_clipboard_text(text: str) -> None:
    ctypes = _windll()
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    CF_UNICODETEXT = 13
    if not user32.OpenClipboard(None):
        raise AppError("系统剪贴板正被占用，没有写入。", "rejected")
    try:
        user32.EmptyClipboard()
        data = text.encode("utf-16-le") + b"\x00\x00"
        handle = kernel32.GlobalAlloc(0x0002, len(data))
        if not handle:
            raise AppError("无法分配剪贴板内存。", "rejected")
        locked = kernel32.GlobalLock(handle)
        ctypes.memmove(locked, data, len(data))
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(CF_UNICODETEXT, handle):
            raise AppError("系统拒绝写入剪贴板。", "rejected")
    finally:
        user32.CloseClipboard()


def get_clipboard_text() -> str:
    ctypes = _windll()
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    CF_UNICODETEXT = 13
    if not user32.OpenClipboard(None):
        raise AppError("系统剪贴板正被占用，没有读取。", "rejected")
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return ""
        locked = kernel32.GlobalLock(handle)
        try:
            return ctypes.wstring_at(locked)
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


class WindowsSystem:
    def lock(self) -> bool:
        return lock_workstation()

    def screensaver(self) -> bool:
        return start_screensaver()

    def sleep(self) -> bool:
        return suspend()

    def set_awake(self, enabled: bool) -> bool:
        return execution_state(enabled)

    def media(self, name: str) -> bool:
        return media_key(name)


def capture_screen():
    """返回虚拟屏幕的 RGB。只应在用户明确确认后调用。"""
    ctypes = _windll()
    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32
    width = user32.GetSystemMetrics(78)  # SM_CXVIRTUALSCREEN
    height = user32.GetSystemMetrics(79)
    left = user32.GetSystemMetrics(76)
    top = user32.GetSystemMetrics(77)
    if width <= 0 or height <= 0 or width * height > 100_000_000:
        raise AppError("无法取得合理的屏幕尺寸，未保存画面。", "rejected")
    desktop = user32.GetDC(0)
    memory = gdi32.CreateCompatibleDC(desktop)
    bitmap = gdi32.CreateCompatibleBitmap(desktop, width, height)
    gdi32.SelectObject(memory, bitmap)
    SRCCOPY = 0x00CC0020
    if not gdi32.BitBlt(memory, 0, 0, width, height, desktop, left, top, SRCCOPY):
        raise AppError("屏幕采集被拒绝。", "rejected")

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", ctypes.c_uint32),
            ("biWidth", ctypes.c_int32),
            ("biHeight", ctypes.c_int32),
            ("biPlanes", ctypes.c_uint16),
            ("biBitCount", ctypes.c_uint16),
            ("biCompression", ctypes.c_uint32),
            ("biSizeImage", ctypes.c_uint32),
            ("biXPelsPerMeter", ctypes.c_int32),
            ("biYPelsPerMeter", ctypes.c_int32),
            ("biClrUsed", ctypes.c_uint32),
            ("biClrImportant", ctypes.c_uint32),
        ]

    header = BITMAPINFOHEADER()
    header.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    header.biWidth = width
    header.biHeight = -height
    header.biPlanes = 1
    header.biBitCount = 24
    header.biCompression = 0
    stride = (width * 3 + 3) & ~3
    buffer = ctypes.create_string_buffer(stride * height)
    gdi32.GetDIBits(memory, bitmap, 0, height, buffer, ctypes.byref(header), 0)
    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory)
    user32.ReleaseDC(0, desktop)
    rgb = bytearray(width * height * 3)
    for y in range(height):
        row = buffer.raw[y * stride : y * stride + width * 3]
        for x in range(width):
            b, g, r = row[x * 3 : x * 3 + 3]
            dest = (y * width + x) * 3
            rgb[dest : dest + 3] = bytes((r, g, b))
    return width, height, bytes(rgb)


def list_windows() -> list[dict]:
    ctypes = _windll()
    import ctypes.wintypes as wintypes

    user32 = ctypes.windll.user32
    rows = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        title = buf.value
        if not title:
            return True
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        box = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(box))
        rows.append(
            {
                "hwnd": int(hwnd),
                "title": title,
                "pid": int(pid.value),
                "x": int(box.left),
                "y": int(box.top),
                "width": int(box.right - box.left),
                "height": int(box.bottom - box.top),
            }
        )
        return True

    user32.EnumWindows(callback, 0)
    return rows


def move_window(hwnd: int, x: int, y: int, w: int, h: int) -> bool:
    ctypes = _windll()
    HWND_TOP = 0
    SWP_SHOWWINDOW = 0x0040
    return bool(ctypes.windll.user32.SetWindowPos(hwnd, HWND_TOP, int(x), int(y), int(w), int(h), SWP_SHOWWINDOW))
