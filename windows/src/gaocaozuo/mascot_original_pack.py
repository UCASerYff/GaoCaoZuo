"""Read the five icons from the original Windows v1.0.0 executable."""

from __future__ import annotations

import hashlib
import os
import stat
import struct
from pathlib import Path

from gaocaozuo.errors import AppError

if os.name == "nt":
    import ctypes.wintypes as w

    from gaocaozuo.native_win import kernel
    from gaocaozuo.ocr_provider_win import _open_windows_file, _windows_file_snapshot


_RELEASE_EXE = "AI-Mascot-Icons.exe"
_RELEASE_SIZE = 2_107_904
_RELEASE_SHA256 = "6e3adb159b7c0fe6ae4bc739e03f7fb33ffd7b5caab6b6fc844a8fae11fa0f75"

# ManifestResource offsets for Icons.<brand>.ico in this exact release. Each
# row points to a little-endian length followed by the raw, embedded ICO.
_CLR_RESOURCES_START = 0x3260
_CLR_RESOURCES_END = _CLR_RESOURCES_START + 1_855_872
_ICON_OFFSETS = {
    "chatgpt": 0x0,
    "claude": 0x52E20,
    "gemini": 0x105228,
    "grok": 0x168B30,
    "deepseek": 0xB30A0,
}
_ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
_ICON_ENTRY = struct.Struct("<BBBBHHII")
_PNG_PREFIX = b"\x89PNG\r\n\x1a\n"
_BAD_RELEASE = "请选择未修改的 AI-Mascot-Icons Windows v1.0.0 原版 EXE 或解压目录。"


def _local_info(path: Path) -> os.stat_result:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise AppError("原版图标包路径必须是本机普通文件或目录。")
    return info


def _read_release(path: Path) -> bytes:
    if os.name == "nt":
        if not path.drive or path.drive.startswith("\\") or ":" in str(path)[len(path.drive):]:
            raise AppError("请选择本机磁盘上的原版图标包。")
        if kernel("GetDriveTypeW", w.UINT, w.LPCWSTR)(path.anchor) not in (2, 3, 5, 6):
            raise AppError("请选择本机磁盘上的原版图标包。")
    for directory in reversed(path.parents):
        if not stat.S_ISDIR(_local_info(directory).st_mode):
            raise AppError(_BAD_RELEASE)

    info = _local_info(path)
    if stat.S_ISDIR(info.st_mode):
        path = path / _RELEASE_EXE
        info = _local_info(path)
    if path.suffix.casefold() != ".exe" or not stat.S_ISREG(info.st_mode) or info.st_size != _RELEASE_SIZE:
        raise AppError(_BAD_RELEASE)

    if os.name == "nt":
        with _open_windows_file(path) as source:
            before = _windows_file_snapshot(source, path)
            if before[0] != _RELEASE_SIZE:
                raise AppError(_BAD_RELEASE)
            contents = source.read(_RELEASE_SIZE + 1)
            if _windows_file_snapshot(source, path) != before:
                raise AppError(_BAD_RELEASE)
    else:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        with os.fdopen(os.open(path, flags), "rb") as source:
            opened = os.fstat(source.fileno())
            if not stat.S_ISREG(opened.st_mode) or opened.st_size != _RELEASE_SIZE or not os.path.samestat(info, opened):
                raise AppError(_BAD_RELEASE)
            contents = source.read(_RELEASE_SIZE + 1)
    if len(contents) != _RELEASE_SIZE or hashlib.sha256(contents).hexdigest() != _RELEASE_SHA256:
        raise AppError(_BAD_RELEASE)
    return contents


def _read_icon(contents: bytes, offset: int) -> bytes:
    start = _CLR_RESOURCES_START + offset + 4
    size, = struct.unpack_from("<I", contents, start - 4)
    end = start + size
    frame_start = 6 + _ICON_ENTRY.size * len(_ICON_SIZES)
    if size < frame_start or end > min(_CLR_RESOURCES_END, len(contents)):
        raise AppError(_BAD_RELEASE)
    icon = contents[start:end]
    if struct.unpack_from("<HHH", icon) != (0, 1, len(_ICON_SIZES)):
        raise AppError(_BAD_RELEASE)
    for index, expected_size in enumerate(_ICON_SIZES):
        width, height, colors, reserved, planes, bits, length, position = _ICON_ENTRY.unpack_from(
            icon, 6 + index * _ICON_ENTRY.size
        )
        if ((width or 256) != expected_size or (height or 256) != expected_size
                or (colors, reserved, planes, bits) != (0, 0, 1, 32)
                or position != frame_start or length < len(_PNG_PREFIX) or position + length > size
                or not icon.startswith(_PNG_PREFIX, position)):
            raise AppError(_BAD_RELEASE)
        frame_start += length
    if frame_start != size:
        raise AppError(_BAD_RELEASE)
    return icon


def load_v1_icons(path: Path) -> dict[str, bytes]:
    """Read the selected original v1 EXE or its folder. Return all five icons or raise AppError."""
    try:
        contents = _read_release(Path(os.path.abspath(path)))
    except (OSError, ValueError) as exc:
        raise AppError("无法读取本机原版图标包，请重新选择原版 EXE 或解压目录。", "unreadable") from exc
    return {icon_id: _read_icon(contents, offset) for icon_id, offset in _ICON_OFFSETS.items()}
