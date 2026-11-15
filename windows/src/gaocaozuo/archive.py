"""ZIP 创建、加密、列表和隔离解压。7Z 只在本机有 7-Zip 时执行。"""

from __future__ import annotations

import hashlib
import io
import os
import shutil
import stat
import subprocess
import time
import uuid
import zlib
import zipfile
from pathlib import Path

from gaocaozuo.errors import AppError

DEFAULT_MAX_BYTES = 20 * 1024 * 1024 * 1024
DEFAULT_MAX_ENTRIES = 100_000


def seven_zip() -> str | None:
    for name in ("7z", "7zz", "7z.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def _zip_crc_table() -> list[int]:
    table = []
    for value in range(256):
        crc = value
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
        table.append(crc & 0xFFFFFFFF)
    return table


_ZIP_CRC_TABLE = _zip_crc_table()


def _zip_crc_byte(ch: int, crc: int) -> int:
    return ((crc >> 8) ^ _ZIP_CRC_TABLE[(crc ^ ch) & 0xFF]) & 0xFFFFFFFF


def _zipcrypto(data: bytes, password: bytes, crc: int) -> bytes:
    key0, key1, key2 = 305419896, 591751049, 878082192

    def update(ch: int) -> None:
        nonlocal key0, key1, key2
        key0 = _zip_crc_byte(ch, key0)
        key1 = (key1 + (key0 & 0xFF)) & 0xFFFFFFFF
        key1 = (key1 * 134775813 + 1) & 0xFFFFFFFF
        key2 = _zip_crc_byte(key1 >> 24, key2)

    for ch in password:
        update(ch)
    header = os.urandom(11) + bytes([(crc >> 24) & 0xFF])
    out = bytearray()
    for ch in header + data:
        keystream = (((key2 | 2) * ((key2 | 2) ^ 1)) >> 8) & 0xFF
        out.append(ch ^ keystream)
        update(ch)
    return bytes(out)


def _dos(timestamp: float | None = None) -> tuple[int, int]:
    clock = time.localtime(timestamp or time.time())
    dostime = (clock.tm_hour << 11) | (clock.tm_min << 5) | (clock.tm_sec // 2)
    dosdate = ((clock.tm_year - 1980) << 9) | (clock.tm_mon << 5) | clock.tm_mday
    return dostime, dosdate


def _safe_arcname(name: str) -> str:
    text = name.replace("\\", "/")
    if text.startswith("/") or re_drive(text):
        raise AppError(f"压缩成员路径越界，已拒绝：{name}", "unsafe")
    parts = [part for part in text.split("/") if part not in {"", "."}]
    if not parts or any(part == ".." for part in parts):
        raise AppError(f"压缩成员路径越界，已拒绝：{name}", "unsafe")
    for part in parts:
        if any(ord(ch) < 32 for ch in part):
            raise AppError(f"压缩成员名称无效：{name}", "unsafe")
    return "/".join(parts)


def re_drive(text: str) -> bool:
    return len(text) >= 2 and text[1] == ":" 


def build_zip(members: list[tuple[str, bytes]], password: str | None = None) -> bytes:
    """members 是 (归档内相对路径, 内容)。密码使用 ZIP 传统加密，不是 AES。"""
    password_bytes = password.encode("utf-8") if password else None
    buffer = io.BytesIO()
    central = bytearray()
    entries = 0
    dostime, dosdate = _dos()
    for name, content in members:
        arcname = _safe_arcname(name)
        encoded = arcname.encode("utf-8")
        crc = zlib.crc32(content) & 0xFFFFFFFF
        compressed = zlib.compress(content)[2:-4]
        method = 8 if len(compressed) < len(content) else 0
        payload = compressed if method == 8 else content
        flag = 0x800
        if password_bytes:
            payload = _zipcrypto(payload, password_bytes, crc)
            flag |= 0x1
        local_offset = buffer.tell()
        header = _local_header(flag, method, dostime, dosdate, crc, len(payload), len(content), encoded)
        buffer.write(header)
        buffer.write(payload)
        central.extend(_central_header(flag, method, dostime, dosdate, crc, len(payload), len(content), encoded, local_offset))
        entries += 1
    cd_offset = buffer.tell()
    buffer.write(central)
    cd_size = buffer.tell() - cd_offset
    buffer.write(struct_eocd(entries, cd_size, cd_offset))
    return buffer.getvalue()


def _local_header(flag, method, dostime, dosdate, crc, comp_size, uncomp_size, name: bytes) -> bytes:
    import struct

    return struct.pack(
        "<4sHHHHHIIIHH",
        b"PK\x03\x04",
        20,
        flag,
        method,
        dostime,
        dosdate,
        crc,
        comp_size,
        uncomp_size,
        len(name),
        0,
    ) + name


def _central_header(flag, method, dostime, dosdate, crc, comp_size, uncomp_size, name: bytes, offset: int) -> bytes:
    import struct

    return struct.pack(
        "<4sHHHHHHIIIHHHHHII",
        b"PK\x01\x02",
        20,
        20,
        flag,
        method,
        dostime,
        dosdate,
        crc,
        comp_size,
        uncomp_size,
        len(name),
        0,
        0,
        0,
        0,
        0o100644 << 16,
        offset,
    ) + name


def struct_eocd(entries: int, cd_size: int, cd_offset: int) -> bytes:
    import struct

    return struct.pack("<4sHHHHIIH", b"PK\x05\x06", 0, 0, entries, entries, cd_size, cd_offset, 0)


def _is_symlink(info: zipfile.ZipInfo) -> bool:
    mode = info.external_attr >> 16
    return stat.S_ISLNK(mode)


def _member_name(info: zipfile.ZipInfo) -> str:
    name = info.filename.replace("\\", "/")
    if name.endswith("/"):
        name = name[:-1]
        if not name:
            return ""
    return _safe_arcname(name)


def inspect_zip(path: Path, password: str | None = None, max_entries: int = DEFAULT_MAX_ENTRIES, max_bytes: int = DEFAULT_MAX_BYTES) -> list[dict]:
    try:
        handle = zipfile.ZipFile(path)
    except zipfile.BadZipFile as exc:
        raise AppError(f"无法读取压缩包：{path.name}", "invalid") from exc
    with handle:
        infos = handle.infolist()
        if len(infos) > max_entries:
            raise AppError("压缩包成员数量超过预算。", "budget")
        total = 0
        rows = []
        for info in infos:
            if _is_symlink(info):
                raise AppError(f"拒绝压缩包中的符号链接：{info.filename}", "unsafe")
            if info.filename.endswith("/"):
                _member_name(info)
                rows.append({"name": info.filename, "size": 0, "directory": True})
                continue
            _member_name(info)
            total += info.file_size
            if total > max_bytes or info.file_size > max_bytes:
                raise AppError("压缩包展开内容超过当前安全预算。", "budget")
            rows.append({"name": info.filename, "size": info.file_size, "directory": False})
        if password is not None:
            # 只验证密码，不把内容写到目标目录。
            for info in infos:
                if info.is_dir() or info.file_size == 0:
                    continue
                try:
                    handle.read(info, pwd=password.encode("utf-8"))
                except RuntimeError as exc:
                    raise AppError("密码不正确。", "password") from exc
                break
        return rows


def extract_zip(
    path: Path,
    destination: Path,
    password: str | None = None,
    members: list[str] | None = None,
    max_entries: int = DEFAULT_MAX_ENTRIES,
    max_bytes: int = DEFAULT_MAX_BYTES,
    deadline: float | None = None,
) -> Path:
    destination = Path(destination)
    if destination.exists():
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
    parent = destination.parent
    if not parent.is_dir():
        raise AppError(f"目录不存在：{parent}", "invalid")
    stage = parent / f".gaocaozuo-extract-{uuid.uuid4().hex}"
    stage.mkdir(mode=0o700)
    committed = False
    try:
        with zipfile.ZipFile(path) as handle:
            infos = handle.infolist()
            if len(infos) > max_entries:
                raise AppError("压缩包成员数量超过预算。", "budget")
            selected = []
            wanted = set(members) if members is not None else None
            total = 0
            for info in infos:
                if wanted is not None and info.filename not in wanted and info.filename.rstrip("/") not in wanted:
                    continue
                if _is_symlink(info):
                    raise AppError(f"拒绝压缩包中的符号链接：{info.filename}", "unsafe")
                if info.is_dir() or info.filename.endswith("/"):
                    name = _member_name(info)
                    if name:
                        (stage / name).mkdir(parents=True, exist_ok=True)
                    continue
                name = _member_name(info)
                total += info.file_size
                if total > max_bytes:
                    raise AppError("压缩包展开内容超过当前安全预算。", "budget")
                if deadline is not None and time.monotonic() > deadline:
                    raise AppError("解压超过时间预算，已停止并清除隔离目录。", "budget")
                selected.append((info, name))
            pwd = password.encode("utf-8") if password is not None else None
            for info, name in selected:
                target = stage / name
                if target.exists():
                    raise AppError(f"压缩包内名称冲突，已停止：{name}", "conflict")
                target.parent.mkdir(parents=True, exist_ok=True)
                try:
                    data = handle.read(info, pwd=pwd)
                except RuntimeError as exc:
                    raise AppError("需要密码或密码不正确。", "password") from exc
                if len(data) != info.file_size and info.file_size:
                    raise AppError(f"成员大小与声明不符：{name}", "invalid")
                target.write_bytes(data)
                resolved = target.resolve()
                if stage.resolve() not in resolved.parents and resolved != stage.resolve():
                    raise AppError(f"解压路径越界：{name}", "unsafe")
        if destination.exists():
            raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
        os.replace(stage, destination)
        committed = True
        return destination
    finally:
        if not committed and stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


class ExtractBatch:
    """已完成的包不会因为下一次密码重试而重新解压。"""

    def __init__(self):
        self.completed: dict[str, str] = {}

    def run(
        self,
        archives: list[Path],
        destination_for,
        password_for,
        **limits,
    ) -> dict:
        done = []
        for archive in archives:
            digest = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
            if digest in self.completed:
                done.append({"archive": str(archive), "destination": self.completed[digest], "skipped": True})
                continue
            password = None
            try:
                destination = extract_zip(archive, destination_for(archive), None, **limits)
            except AppError as exc:
                if exc.code != "password":
                    raise AppError(
                        exc.message + ("" if not done else f"\n已完成的 {len(done)} 项保留。"),
                        exc.code,
                    ) from exc
                supplied = password_for(archive, incorrect=False)
                if supplied is None:
                    raise AppError(f"已取消解压；已完成的 {len(done)} 项保留。", "cancelled") from exc
                try:
                    destination = extract_zip(archive, destination_for(archive), supplied, **limits)
                except AppError as again:
                    if again.code == "password":
                        raise AppError(f"密码不正确。已完成的 {len(self.completed)} 项保留，未重新解压。", "password") from again
                    raise
                password = supplied
            self.completed[digest] = str(destination)
            done.append({"archive": str(archive), "destination": str(destination), "skipped": False, "usedPassword": password is not None})
        return {"items": done}


def create_zip(sources: list[Path], destination: Path, password: str | None = None) -> Path:
    if destination.exists():
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
    members: list[tuple[str, bytes]] = []
    for source in sources:
        source = Path(source)
        if source.is_symlink():
            raise AppError(f"暂不处理符号链接：{source}", "unsupported")
        if source.is_file():
            members.append((source.name, source.read_bytes()))
        elif source.is_dir():
            for current, dirs, files in os.walk(source):
                dirs.sort()
                for name in sorted(files):
                    file_path = Path(current) / name
                    if file_path.is_symlink():
                        raise AppError(f"暂不处理符号链接：{file_path}", "unsupported")
                    relative = Path(source.name) / file_path.relative_to(source)
                    members.append((relative.as_posix(), file_path.read_bytes()))
        else:
            raise AppError(f"暂不处理：{source}", "unsupported")
    if not members:
        raise AppError("没有可压缩的文件。", "invalid")
    destination.write_bytes(build_zip(members, password))
    return destination


def split_file(path: Path, part_bytes: int) -> list[Path]:
    if part_bytes < 64 * 1024:
        raise AppError("分卷不能小于 64 KiB。", "invalid")
    data = path.read_bytes()
    parts = []
    index = 1
    for start in range(0, len(data), part_bytes):
        part = path.parent / f"{path.name}.{index:03d}"
        if part.exists():
            raise AppError(f"已存在同名项目，未覆盖：{part}", "conflict")
        part.write_bytes(data[start : start + part_bytes])
        parts.append(part)
        index += 1
    return parts


def create_7z(sources: list[Path], destination: Path, password: str | None = None, solid: bool = True, split_mb: int | None = None) -> Path:
    tool = seven_zip()
    if tool is None:
        raise AppError("本机没有 7-Zip 可执行文件，不能创建 7Z、固实压缩或 7-Zip 分卷。ZIP 仍可直接创建。", "unavailable")
    if destination.exists():
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
    command = [tool, "a", "-t7z", "-bso0", "-bsp0", "-y", f"-ms={'on' if solid else 'off'}", str(destination)]
    if password:
        command.append(f"-p{password}")
        command.append("-mhe=on")
    if split_mb:
        command.append(f"-v{int(split_mb)}m")
    command.extend(str(path) for path in sources)
    try:
        completed = subprocess.run(command, check=False, capture_output=True)
    except OSError as exc:
        raise AppError("无法启动 7-Zip。", "unavailable") from exc
    if completed.returncode != 0:
        raise AppError("7-Zip 没有完成压缩。密码和路径没有写入日志。", "invalid")
    return destination
