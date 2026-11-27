"""Windows clipboard formats and a sequence-owned temporary paste lease."""

from __future__ import annotations

import ctypes as ct
import io
import os
import struct
from contextlib import contextmanager
from ctypes import wintypes as wt
from pathlib import Path

from gaocaozuo.errors import AppError

CF_TEXT, CF_BITMAP, CF_OEMTEXT, CF_DIB = 1, 2, 7, 8
CF_UNICODETEXT, CF_HDROP, CF_LOCALE, CF_DIBV5 = 13, 15, 16, 17
LIMIT = 32 * 1024 * 1024
HISTORY_LIMIT = 2 * 1024 * 1024
PRIVATE_FORMATS = (
    "ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory",
    "CanUploadToCloudClipboard", "Clipboard Viewer Ignore", "ClipboardViewerIgnore",
)
PASSWORD_APPS = {"1password", "bitwarden", "keepass", "keepassxc", "enpass", "credentialuibroker", "logonui"}


def _prototype(dll, name, return_type, *args):
    function = getattr(dll, name)
    function.restype = return_type
    function.argtypes = args
    return function


class GuiThreadInfo(ct.Structure):
    _fields_ = [
        ("size", wt.DWORD), ("flags", wt.DWORD), ("active", wt.HWND), ("focus", wt.HWND),
        ("capture", wt.HWND), ("menu", wt.HWND), ("move_size", wt.HWND), ("caret", wt.HWND),
        ("caret_rect", wt.RECT),
    ]


class WindowsClipboard:
    def __init__(self):
        user = ct.WinDLL("user32", use_last_error=True)
        kernel = ct.WinDLL("kernel32", use_last_error=True)
        self.open = _prototype(user, "OpenClipboard", wt.BOOL, wt.HWND)
        self.close = _prototype(user, "CloseClipboard", wt.BOOL)
        self.empty = _prototype(user, "EmptyClipboard", wt.BOOL)
        self.get = _prototype(user, "GetClipboardData", wt.HANDLE, wt.UINT)
        self.set = _prototype(user, "SetClipboardData", wt.HANDLE, wt.UINT, wt.HANDLE)
        self.enum = _prototype(user, "EnumClipboardFormats", wt.UINT, wt.UINT)
        self.sequence = _prototype(user, "GetClipboardSequenceNumber", wt.DWORD)
        self.owner = _prototype(user, "GetClipboardOwner", wt.HWND)
        self.foreground = _prototype(user, "GetForegroundWindow", wt.HWND)
        self.window_thread = _prototype(user, "GetWindowThreadProcessId", wt.DWORD, wt.HWND, ct.POINTER(wt.DWORD))
        self.gui_info = _prototype(user, "GetGUIThreadInfo", wt.BOOL, wt.DWORD, ct.POINTER(GuiThreadInfo))
        self.class_name = _prototype(user, "GetClassNameW", ct.c_int, wt.HWND, wt.LPWSTR, ct.c_int)
        self.style = _prototype(user, "GetWindowLongW", ct.c_long, wt.HWND, ct.c_int)
        self.create_window = _prototype(user, "CreateWindowExW", wt.HWND, wt.DWORD, wt.LPCWSTR, wt.LPCWSTR,
                                        wt.DWORD, ct.c_int, ct.c_int, ct.c_int, ct.c_int, wt.HWND,
                                        wt.HMENU, wt.HINSTANCE, wt.LPVOID)
        self.destroy_window = _prototype(user, "DestroyWindow", wt.BOOL, wt.HWND)
        register = _prototype(user, "RegisterClipboardFormatW", wt.UINT, wt.LPCWSTR)
        self.named = {name: register(name) for name in (*PRIVATE_FORMATS, "HTML Format", "Rich Text Format", "PNG", "Preferred DropEffect")}
        self.alloc = _prototype(kernel, "GlobalAlloc", wt.HGLOBAL, wt.UINT, ct.c_size_t)
        self.free = _prototype(kernel, "GlobalFree", wt.HGLOBAL, wt.HGLOBAL)
        self.size = _prototype(kernel, "GlobalSize", ct.c_size_t, wt.HGLOBAL)
        self.lock = _prototype(kernel, "GlobalLock", wt.LPVOID, wt.HGLOBAL)
        self.unlock = _prototype(kernel, "GlobalUnlock", wt.BOOL, wt.HGLOBAL)
        self.open_process = _prototype(kernel, "OpenProcess", wt.HANDLE, wt.DWORD, wt.BOOL, wt.DWORD)
        self.close_handle = _prototype(kernel, "CloseHandle", wt.BOOL, wt.HANDLE)
        self.process_path = _prototype(kernel, "QueryFullProcessImageNameW", wt.BOOL, wt.HANDLE, wt.DWORD, wt.LPWSTR, ct.POINTER(wt.DWORD))
        shell = ct.WinDLL("shell32", use_last_error=True)
        self.drop_query = _prototype(shell, "DragQueryFileW", wt.UINT, wt.HANDLE, wt.UINT, wt.LPWSTR, wt.UINT)

    @contextmanager
    def opened(self, write=False):
        window = self.create_window(0, "STATIC", None, 0, 0, 0, 0, 0, wt.HWND(-3), None, None, None) if write else None
        if write and not window:
            raise AppError("系统未提供可以写入剪贴板的窗口。", "unavailable")
        try:
            if not self.open(window):
                raise AppError("系统剪贴板正被占用，请重试。", "busy")
            try:
                yield
            finally:
                self.close()
        finally:
            if window:
                self.destroy_window(window)

    def formats(self) -> list[int]:
        formats = []
        current = self.enum(0)
        while current:
            formats.append(current)
            current = self.enum(current)
        return formats

    def read_format(self, number: int, limit=LIMIT) -> bytes | None:
        handle = self.get(number)
        if not handle:
            return None
        size = self.size(handle)
        if not size or size > limit:
            raise AppError("剪贴板格式无法完整保存，或内容超过大小限制。", "budget")
        address = self.lock(handle)
        if not address:
            raise AppError("无法读取完整的系统剪贴板。", "rejected")
        try:
            return ct.string_at(address, size)
        finally:
            self.unlock(handle)

    @staticmethod
    def decode_text(data: bytes) -> str:
        return data[:len(data) - len(data) % 2].decode("utf-16-le", errors="replace").split("\0", 1)[0]

    def text(self) -> str:
        with self.opened():
            self.require_readable(self.formats())
            data = self.read_format(CF_UNICODETEXT)
        if data is None:
            raise AppError("剪贴板没有文字。", "missing")
        return self.decode_text(data)

    def image_bytes(self) -> bytes:
        from PIL import Image

        with self.opened():
            formats = self.formats()
            self.require_readable(formats)
            png = self.read_format(self.named["PNG"]) if self.named["PNG"] in formats else None
            data = png or (self.read_format(CF_DIBV5 if CF_DIBV5 in formats else CF_DIB) if set(formats) & {CF_BITMAP, CF_DIB, CF_DIBV5} else None)
        if not data:
            raise AppError("剪贴板没有图片。", "missing")
        try:
            with Image.open(io.BytesIO(data), formats=["PNG" if png else "DIB"]) as image, io.BytesIO() as output:
                if image.width * image.height > 40_000_000:
                    raise AppError("剪贴板图片超过像素上限。", "budget")
                image.save(output, "PNG")
                return output.getvalue()
        except OSError as exc:
            raise AppError("无法解码剪贴板图片。", "invalid") from exc

    def require_readable(self, formats):
        if self.named[PRIVATE_FORMATS[0]] in formats or any(self.named[name] in formats for name in PRIVATE_FORMATS[3:]):
            raise AppError("系统剪贴板含受保护内容。", "blocked")
        history = self.named[PRIVATE_FORMATS[1]]
        if history in formats and (self.read_format(history, 16) or b'')[:4] == bytes(4):
            raise AppError("系统剪贴板含受保护内容。", "blocked")

    def snapshot(self) -> tuple[int, dict[int, bytes]]:
        with self.opened():
            before, formats = self.sequence(), self.formats()
            self.require_readable(formats)
            has_dib = CF_DIB in formats or CF_DIBV5 in formats
            supported = {CF_TEXT, CF_OEMTEXT, CF_DIB, CF_UNICODETEXT, CF_HDROP, CF_LOCALE, CF_DIBV5, *self.named.values()}
            original = {}
            limit = LIMIT
            for number in formats:
                if number == CF_BITMAP and has_dib:
                    continue
                if number not in supported:
                    raise AppError("原剪贴板含当前无法还原的格式。可改用显式复制后手动粘贴。", "unsupported")
                data = self.read_format(number, limit)
                if data is None:
                    raise AppError("原剪贴板无法完整保留。", "rejected")
                original[number] = data
                limit -= len(data)
            after = self.sequence()
            if before != after:
                raise AppError("读取时系统剪贴板发生变化，请重试。", "changed")
            return after, original

    def replace(self, formats: dict[int, bytes], expected=None, fallback=None) -> int:
        handles = self._prepare(formats)
        rollback = {}
        try:
            rollback = self._prepare(fallback or {})
            with self.opened(write=True):
                if expected is not None and self.sequence() != expected:
                    raise AppError("系统剪贴板已变化，保留新内容。", "changed")
                if not self.empty():
                    raise AppError("系统拒绝清空剪贴板。", "rejected")
                try:
                    self._install(handles)
                except AppError:
                    if fallback is not None and self.empty():
                        self._install(rollback)
                    raise
                return self.sequence()
        finally:
            for handle in (*handles.values(), *rollback.values()):
                self.free(handle)

    def _prepare(self, formats):
        handles = {}
        try:
            for format_id, value in formats.items():
                handle = self.alloc(0x42, max(1, len(value)))
                if not handle:
                    raise AppError("无法分配系统剪贴板内存。", "rejected")
                handles[format_id] = handle
                address = self.lock(handle)
                if not address:
                    raise AppError("无法准备系统剪贴板内存。", "rejected")
                try:
                    ct.memmove(address, value, len(value))
                finally:
                    self.unlock(handle)
        except BaseException:
            for handle in handles.values():
                self.free(handle)
            raise
        return handles

    def _install(self, handles):
        for number in list(handles):
            if not self.set(number, handles[number]):
                raise AppError("系统拒绝写入剪贴板格式。", "rejected")
            del handles[number]

    def plain_formats(self, text: str, *, temporary=False) -> dict[int, bytes]:
        if "\0" in text or len(text) > LIMIT // 2:
            raise AppError("文字含空字符或超过剪贴板大小限制。", "invalid")
        formats = {CF_UNICODETEXT: (text + "\0").encode("utf-16-le")}
        return formats | self.private_formats() if temporary else formats

    def private_formats(self):
        return {self.named[name]: bytes(4) for name in PRIVATE_FORMATS[:3]}

    def focus_details(self, window: int) -> tuple[int, bool, bool]:
        thread = self.window_thread(window, None)
        info = GuiThreadInfo(size=ct.sizeof(GuiThreadInfo))
        if not thread or not self.gui_info(thread, ct.byref(info)) or not info.focus:
            return 0, False, False
        name = ct.create_unicode_buffer(128)
        self.class_name(info.focus, name, len(name))
        style = self.style(info.focus, -16)
        edit = name.value.casefold()
        is_edit = edit == "edit" or edit.startswith("richedit")
        return int(info.focus), bool(style & 0x20) and is_edit, is_edit and not bool(style & 0x800)

    def observe(self, before: int, excluded) -> dict | None:
        window = self.foreground()
        owner = self.owner()
        pid = wt.DWORD()
        owner_pid = wt.DWORD()
        if not window or not owner or not self.window_thread(window, ct.byref(pid)) or not self.window_thread(owner, ct.byref(owner_pid)) or pid.value != owner_pid.value or pid.value == os.getpid():
            return None
        focus, secure, _editable = self.focus_details(window)
        if not focus or secure:
            return None
        process = self.open_process(0x1000, False, pid.value)
        if not process:
            return None
        name = ct.create_unicode_buffer(1024)
        length = wt.DWORD(len(name))
        try:
            if not self.process_path(process, 0, name, ct.byref(length)):
                return None
        finally:
            self.close_handle(process)
        source = Path(name.value).stem.casefold()
        if source in PASSWORD_APPS or any(source in str(value).casefold() for value in excluded):
            return None
        with self.opened():
            formats = set(self.formats())
            self.require_readable(formats)
            text = self.decode_text(self.read_format(CF_UNICODETEXT, HISTORY_LIMIT) or b'') if CF_UNICODETEXT in formats else ""
            parts = []
            if CF_HDROP in formats:
                drop = self.get(CF_HDROP)
                count = self.drop_query(drop, 0xFFFFFFFF, None, 0) if drop else 0
                for index in range(min(count, 100)):
                    size = self.drop_query(drop, index, None, 0)
                    if size and size <= 32767:
                        path = ct.create_unicode_buffer(size + 1)
                        self.drop_query(drop, index, path, size + 1)
                        parts.append({"kind": "file", "path": path.value})
            png_id = self.named["PNG"]
            png = self.read_format(png_id, HISTORY_LIMIT) if png_id in formats else None
            dib = self.read_format(CF_DIBV5 if CF_DIBV5 in formats else CF_DIB, HISTORY_LIMIT) if not png and (CF_DIB in formats or CF_DIBV5 in formats) else None
            rich = {label: self.read_format(self.named[label], HISTORY_LIMIT) for label in ("HTML Format", "Rich Text Format") if self.named[label] in formats}
            if self.sequence() != before or self.foreground() != window or self.owner() != owner or self.focus_details(window)[:2] != (focus, False):
                return None
        if dib:
            from PIL import Image

            with Image.open(io.BytesIO(dib), formats=["DIB"]) as image, io.BytesIO() as output:
                if image.width * image.height <= 16_000_000:
                    image.save(output, "PNG")
                    png = output.getvalue()
        if not (text or parts or png):
            return None
        return {"text": text, "parts": parts, "source": source, "png": png, "rich": rich}

    def part_formats(self, parts, *, temporary=False):
        text = "\n".join(part["text"] for part in parts if part["kind"] == "text" and part.get("text"))
        formats = self.plain_formats(text) if text else {}
        paths = [part["path"] for part in parts if part["kind"] in {"file", "folder"} and part.get("path")]
        pictures = [part["path"] for part in parts if part["kind"] == "image" and part.get("path")]
        if pictures:
            from PIL import Image

            for picture in pictures[:1]:
                with Image.open(picture) as image, io.BytesIO() as output:
                    if image.width * image.height > 16_000_000:
                        raise AppError("图片超过系统剪贴板像素限制。", "budget")
                    image.convert("RGB").save(output, "BMP")
                    formats[CF_DIB] = output.getvalue()[14:]
            if len(pictures) > 1:
                paths.extend(pictures)
        if paths:
            if any("\0" in path or not os.path.isabs(path) for path in paths):
                raise AppError("只能复制绝对文件路径。", "invalid")
            formats[CF_HDROP] = struct.pack("<IiiII", 20, 0, 0, 0, 1) + ("\0".join(paths) + "\0\0").encode("utf-16-le")
            formats[self.named["Preferred DropEffect"]] = (1).to_bytes(4, "little")
        if not formats:
            raise AppError("没有可写入剪贴板的内容。", "missing")
        return formats | self.private_formats() if temporary else formats
