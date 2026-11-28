"""Edit only the icon fields of a Windows Shell Link (MS-SHLLINK)."""

from __future__ import annotations

import base64
import os
import struct
from pathlib import Path
from uuid import UUID

from gaocaozuo.errors import AppError


HEADER_SIZE = 0x4C
LINK_CLSID = UUID("00021401-0000-0000-c000-000000000046").bytes_le
FLAG_ICON = 0x40
FLAG_UNICODE = 0x80
FLAG_EXP_ICON = 0x4000
ICON_ENV = 0xA0000007
ICON_ENV_SIZE = 0x314


def _invalid():
    return AppError("无法识别此 Windows 快捷方式的结构。", "invalid-shortcut")


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _cut(data: bytes, start: int, length: int, minimum: int = 0) -> bytes:
    if length < minimum or start + length > len(data):
        raise _invalid()
    return data[start:start + length]


def _ansi_codec() -> str:
    return "mbcs" if os.name == "nt" else "cp1252"


def _terminated(data: bytes, width: int, encoding: str) -> str:
    end = next((i for i in range(0, len(data), width) if data[i:i + width] == bytes(width)), len(data))
    return data[:end].decode(encoding, errors="replace")


class ShellLink:
    def __init__(self, data: bytes):
        if len(data) < HEADER_SIZE + 4 or data[:20] != struct.pack("<I", HEADER_SIZE) + LINK_CLSID:
            raise _invalid()
        self.header = data[:HEADER_SIZE]
        self.flags = _u32(data, 20)
        self.unicode = bool(self.flags & FLAG_UNICODE)
        self.icon_index = struct.unpack_from("<i", data, 56)[0]
        self.info = b""
        offset = HEADER_SIZE
        if self.flags & 1:
            _cut(data, offset, 2)
            offset += len(_cut(data, offset, 2 + struct.unpack_from("<H", data, offset)[0]))
        if self.flags & 2:
            _cut(data, offset, 4)
            self.info = _cut(data, offset, _u32(data, offset), 28)
            offset += len(self.info)
        width = 2 if self.unicode else 1
        for flag in (4, 8, 16, 32):
            if self.flags & flag:
                _cut(data, offset, 2)
                offset += len(_cut(data, offset, 2 + width * struct.unpack_from("<H", data, offset)[0]))
        self.prefix = data[HEADER_SIZE:offset]
        self.icon = None
        if self.flags & FLAG_ICON:
            _cut(data, offset, 2)
            count = struct.unpack_from("<H", data, offset)[0]
            self.icon = _cut(data, offset + 2, count * width)
            offset += 2 + len(self.icon)

        self.blocks = []
        self.icon_env = None
        self.icon_env_index = None
        while len(data) - offset >= 4:
            size = _u32(data, offset)
            if size < 4:
                self.suffix = data[offset:]
                break
            block = _cut(data, offset, size, 8)
            if _u32(block, 4) == ICON_ENV:
                if size != ICON_ENV_SIZE or self.icon_env is not None:
                    raise _invalid()
                self.icon_env, self.icon_env_index = block, len(self.blocks)
            else:
                self.blocks.append(block)
            offset += size
        else:
            raise _invalid()
        if bool(self.flags & FLAG_EXP_ICON) != (self.icon_env is not None):
            raise _invalid()

    @property
    def icon_path(self) -> str:
        if self.icon_env:
            value = _terminated(self.icon_env[268:], 2, "utf-16-le") or _terminated(self.icon_env[8:268], 1, _ansi_codec())
            if value:
                return value
        return (self.icon or b"").decode("utf-16-le" if self.unicode else _ansi_codec(), errors="replace")

    @property
    def local_target(self) -> str:
        if not self.info or not _u32(self.info, 8) & 1:
            return ""
        header_size = _u32(self.info, 4)
        if len(self.info) >= 36 and header_size >= 36:
            offset = _u32(self.info, 28)
            if header_size <= offset < len(self.info):
                return _terminated(self.info[offset:], 2, "utf-16-le")
        offset = _u32(self.info, 16)
        return _terminated(self.info[offset:], 1, _ansi_codec()) if header_size <= offset < len(self.info) else ""

    def icon_metadata(self) -> dict:
        encode = lambda value: base64.b64encode(value).decode("ascii") if value is not None else None
        return {"index": self.icon_index, "string": encode(self.icon), "environment": encode(self.icon_env),
                "environmentIndex": self.icon_env_index}

    def with_icon(self, path: Path) -> bytes:
        try:
            data = str(path).encode("utf-16-le" if self.unicode else _ansi_codec())
        except UnicodeEncodeError as exc:
            raise AppError("旧版快捷方式不能保存此图标路径。", "unsupported-shortcut") from exc
        if len(data) // (2 if self.unicode else 1) >= 260:
            raise AppError("图标路径过长，快捷方式未修改。", "invalid")
        return self._replace(0, data, None, None)

    def restored(self, metadata: dict) -> bytes:
        try:
            icon = base64.b64decode(metadata["string"], validate=True) if metadata["string"] is not None else None
            env = base64.b64decode(metadata["environment"], validate=True) if metadata["environment"] is not None else None
            position = metadata["environmentIndex"]
            index = metadata["index"]
            width = 2 if self.unicode else 1
            if icon is not None and (len(icon) % width or len(icon) // width > 65535):
                raise ValueError
            if env is not None and (len(env) != ICON_ENV_SIZE or _u32(env, 0) != ICON_ENV_SIZE or _u32(env, 4) != ICON_ENV
                                    or type(position) is not int or not 0 <= position <= len(self.blocks)):
                raise ValueError
            if type(index) is not int or not -(2 ** 31) <= index < 2 ** 31:
                raise ValueError
            return self._replace(index, icon, env, position)
        except (TypeError, ValueError, KeyError, struct.error) as exc:
            raise AppError("原始图标记录无法读取。", "corrupt") from exc

    def _replace(self, index: int, icon: bytes | None, env: bytes | None, position: int | None) -> bytes:
        header = bytearray(self.header)
        flags = self.flags & ~(FLAG_ICON | FLAG_EXP_ICON)
        encoded_icon = b""
        if icon is not None:
            flags |= FLAG_ICON
            encoded_icon = struct.pack("<H", len(icon) // (2 if self.unicode else 1)) + icon
        blocks = list(self.blocks)
        if env is not None:
            flags |= FLAG_EXP_ICON
            blocks.insert(position, env)
        struct.pack_into("<I", header, 20, flags)
        struct.pack_into("<i", header, 56, index)
        return bytes(header) + self.prefix + encoded_icon + b"".join(blocks) + self.suffix
