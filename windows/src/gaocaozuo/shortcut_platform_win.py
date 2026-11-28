"""Read and update user-selected local shortcuts and their Windows icon resources."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import os
import stat
import tempfile
from pathlib import Path
from uuid import UUID

from PIL import Image

from gaocaozuo.errors import AppError
from gaocaozuo.native_win import bind, kernel, user


def local_path(value: str) -> Path:
    if not isinstance(value, str):
        raise AppError("请选择受支持的本地文件。", "invalid")
    raw = Path(value)
    if not raw.is_absolute() or not raw.drive or raw.drive.startswith("\\") or ":" in str(raw)[2:]:
        raise AppError("请选择受支持的本地文件。", "invalid")
    if kernel("GetDriveTypeW", w.UINT, w.LPCWSTR)(raw.anchor) not in (2, 3, 5, 6):
        raise AppError("只支持本地磁盘上的文件。", "invalid")
    return raw


def source_path(value: str, suffixes: set[str], limit: int) -> Path:
    raw = local_path(value)
    if raw.suffix.casefold() not in suffixes:
        raise AppError("请选择受支持的本地文件。", "invalid")
    info = raw.lstat()
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise AppError("此文件是链接或云占位，已跳过。", "invalid")
    path = raw.resolve(strict=True)
    if not path.drive or path.drive.startswith("\\") or ":" in str(path)[2:] or path.suffix.casefold() not in suffixes:
        raise AppError("请选择受支持的本地文件。", "invalid")
    if info.st_size <= 0 or info.st_size > limit:
        raise AppError("文件大小超出可读取范围。", "invalid")
    return path


def user_folders() -> tuple[tuple[str, Path], ...]:
    definitions = (("desktop", "B4BFCC3A-DB2C-424C-B029-7FE99A87C641"),
                   ("start", "625B53C3-AB48-4EC1-BA1F-A1EF4146FC19"))
    get = bind("shell32", "SHGetKnownFolderPath", c.c_long, c.c_void_p, w.DWORD, w.HANDLE, c.POINTER(w.LPWSTR))
    free = bind("ole32", "CoTaskMemFree", None, c.c_void_p)
    folders = []
    for key, identifier in definitions:
        value = w.LPWSTR()
        guid = (c.c_ubyte * 16).from_buffer_copy(UUID(identifier).bytes_le)
        try:
            if get(c.byref(guid), 0x4000, None, c.byref(value)) == 0 and value.value:
                folders.append((key, Path(value.value)))
        finally:
            if value:
                free(value)
    return tuple(folders)


def replace_shortcut(path: Path, before: bytes, after: bytes) -> None:
    if path == path.parent or path.suffix.casefold() != ".lnk":
        raise AppError("只支持 Windows .lnk 快捷方式。", "invalid")
    descriptor, name = tempfile.mkstemp(prefix=".gaocaozuo-icon-", dir=path.parent)
    staged = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        if source_path(str(path), {".lnk"}, len(before)) != path:
            raise AppError("快捷方式位置已变化。", "changed")
        with path.open("rb") as stream:
            if stream.read(len(before) + 1) != before:
                raise AppError("快捷方式已被其他程序修改。", "changed")
        replace = kernel("ReplaceFileW", w.BOOL, w.LPCWSTR, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_void_p, c.c_void_p)
        if not replace(str(path), str(staged), None, 0, None, None):
            raise c.WinError(c.get_last_error())
    finally:
        staged.unlink(missing_ok=True)


def notify_shortcut(path: Path) -> None:
    bind("shell32", "SHChangeNotify", None, c.c_long, w.UINT, w.LPCWSTR, c.c_void_p)(0x2000, 5, str(path), None)


class _BitmapInfo(c.Structure):
    _fields_ = (("length", w.DWORD), ("width", w.LONG), ("height", w.LONG), ("planes", w.WORD), ("bits", w.WORD),
                ("extra", w.DWORD * 6), ("colors", w.DWORD))


def extracted_icon(path: Path, index: int) -> Image.Image | None:
    extract = bind("shell32", "ExtractIconExW", w.UINT, w.LPCWSTR, c.c_int, c.POINTER(w.HICON), c.c_void_p, w.UINT)
    icon = w.HICON()
    if extract(str(path), index, c.byref(icon), None, 1) != 1 or not icon:
        return None
    try:
        black, white = _draw_icon(icon, 0), _draw_icon(icon, 255)
        if black is None or white is None:
            return None
        result = bytearray()
        for offset in range(0, len(black), 3):
            rgb = black[offset:offset + 3]
            alpha = 255 - min(255, max(0, max(white[offset + channel] - rgb[channel] for channel in range(3))))
            result.extend(min(255, round(value * 255 / alpha)) if alpha else 0 for value in rgb)
            result.append(alpha)
        return Image.frombytes("RGBA", (64, 64), bytes(result))
    finally:
        user("DestroyIcon", w.BOOL, w.HICON)(icon)


def _draw_icon(icon, background: int) -> bytes | None:
    size = 64
    gdi = lambda name, result, *args: bind("gdi32", name, result, *args)
    dc = gdi("CreateCompatibleDC", w.HDC, w.HDC)(None)
    if not dc:
        return None
    bitmap = previous = None
    try:
        info = _BitmapInfo(length=40, width=size, height=-size, planes=1, bits=32)
        bits = c.c_void_p()
        bitmap = gdi("CreateDIBSection", w.HBITMAP, w.HDC, c.POINTER(_BitmapInfo), w.UINT,
                     c.POINTER(c.c_void_p), w.HANDLE, w.DWORD)(dc, c.byref(info), 0, c.byref(bits), None, 0)
        if not bitmap or not bits:
            return None
        select = gdi("SelectObject", w.HGDIOBJ, w.HDC, w.HGDIOBJ)
        previous = select(dc, bitmap)
        if not previous:
            return None
        c.memset(bits, background, size * size * 4)
        draw = user("DrawIconEx", w.BOOL, w.HDC, c.c_int, c.c_int, w.HICON, c.c_int, c.c_int, w.UINT, w.HBRUSH, w.UINT)
        if not draw(dc, 0, 0, icon, size, size, 0, None, 3):
            return None
        gdi("GdiFlush", w.BOOL)()
        return Image.frombytes("RGB", (size, size), c.string_at(bits, size * size * 4), "raw", "BGRX").tobytes()
    finally:
        if previous:
            select(dc, previous)
        if bitmap:
            gdi("DeleteObject", w.BOOL, w.HGDIOBJ)(bitmap)
        gdi("DeleteDC", w.BOOL, w.HDC)(dc)
