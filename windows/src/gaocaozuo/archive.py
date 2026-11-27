"""ZIP/7Z archives, with isolated preflight and extraction."""

from __future__ import annotations

import hashlib
import io
import os
import re
import shutil
import stat
import time
import uuid
import zlib
import zipfile
from contextlib import contextmanager
from pathlib import Path

from gaocaozuo.errors import AppError

DEFAULT_MAX_BYTES = 20 * 1024 * 1024 * 1024
DEFAULT_MAX_ENTRIES = 100_000


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
    parts = text.split("/")
    if not parts or any(part == ".." for part in parts):
        raise AppError(f"压缩成员路径越界，已拒绝：{name}", "unsafe")
    for part in parts:
        base = part.split(".", 1)[0].rstrip().upper()
        reserved = base in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"} or re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", base)
        if not part or part.endswith((".", " ")) or reserved or any(ord(ch) < 32 or ch in ':*?"<>|' for ch in part):
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
        arcname = _safe_arcname(name[:-1]) + "/" if name.endswith("/") else _safe_arcname(name)
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
    return stat.S_IFMT(mode) not in {0, stat.S_IFREG, stat.S_IFDIR} or bool(info.external_attr & 0x400)


def _member_name(info: zipfile.ZipInfo) -> str:
    name = info.orig_filename.replace("\\", "/")
    if name.endswith("/"):
        name = name[:-1]
        if not name:
            return ""
    return _safe_arcname(name)


def zip_reader(path):
    try:
        import pyzipper
    except ImportError:
        return zipfile.ZipFile(path)
    return pyzipper.AESZipFile(path)


def inspect_zip(path: Path, password: str | None = None, max_entries: int = DEFAULT_MAX_ENTRIES, max_bytes: int = DEFAULT_MAX_BYTES) -> list[dict]:
    try:
        handle = zip_reader(path)
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
                    with handle.open(info, pwd=password.encode("utf-8")) as member:
                        member.read(1)
                except (RuntimeError, ValueError) as exc:
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
        with zip_reader(path) as handle:
            infos = handle.infolist()
            if len(infos) > max_entries:
                raise AppError("压缩包成员数量超过预算。", "budget")
            selected = []
            wanted = set(members) if members is not None else None
            total = 0
            known = set()
            for info in infos:
                if wanted is not None and info.filename not in wanted and info.filename.rstrip("/") not in wanted:
                    continue
                if _is_symlink(info):
                    raise AppError(f"拒绝压缩包中的符号链接：{info.filename}", "unsafe")
                name = _member_name(info)
                key = name.casefold()
                if key in known:
                    raise AppError(f"压缩包内名称冲突，已停止：{name}", "conflict")
                known.add(key)
                if info.is_dir() or info.filename.endswith("/"):
                    if name:
                        (stage / name).mkdir(parents=True, exist_ok=True)
                    continue
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
                    size = 0
                    with handle.open(info, pwd=pwd) as source, target.open("xb") as output:
                        while chunk := source.read(1024 * 1024):
                            size += len(chunk)
                            if size > info.file_size or (deadline is not None and time.monotonic() > deadline):
                                raise AppError("解压超过大小或时间预算。", "budget")
                            output.write(chunk)
                except (RuntimeError, ValueError) as exc:
                    raise AppError("需要密码或密码不正确。", "password") from exc
                if size != info.file_size:
                    raise AppError(f"成员大小与声明不符：{name}", "invalid")
                resolved = target.resolve()
                if stage.resolve() not in resolved.parents and resolved != stage.resolve():
                    raise AppError(f"解压路径越界：{name}", "unsafe")
        if destination.exists():
            raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
        os.rename(stage, destination)
        committed = True
        return destination
    finally:
        if not committed and stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


class ExtractBatch:
    """已完成的包不会因为下一次密码重试而重新解压。"""

    def __init__(self):
        self.completed: dict[tuple, str] = {}

    def run(
        self,
        archives: list[Path],
        destination_for,
        password_for,
        **limits,
    ) -> dict:
        done = []
        for archive in archives:
            source, components = archive_parts(archive)
            digest = (str(source.resolve()), tuple((part.stat().st_size, part.stat().st_mtime_ns) for part in components))
            if digest in self.completed:
                done.append({"archive": str(archive), "destination": self.completed[digest], "skipped": True})
                continue
            password = None
            try:
                destination = extract_archive(archive, destination_for(archive), None, **limits)
            except AppError as exc:
                if exc.code != "password":
                    raise AppError(
                        exc.message + ("" if not done else f"\n已完成的 {len(done)} 项保留。"),
                        exc.code,
                    ) from exc
                supplied = password_for(archive, incorrect=False)
                if supplied is None:
                    raise AppError(f"需要输入解压密码。已完成的 {len(done)} 项保留。", "password") from exc
                try:
                    destination = extract_archive(archive, destination_for(archive), supplied, **limits)
                except AppError as again:
                    if again.code == "password":
                        raise AppError(f"密码不正确。已完成的 {len(self.completed)} 项保留，未重新解压。", "password") from again
                    raise
                password = supplied
            self.completed[digest] = str(destination)
            done.append({"archive": str(archive), "destination": str(destination), "skipped": False, "usedPassword": password is not None})
        return {"items": done}


def _source_rows(sources):
    seen = set()

    def walk(source, name):
        info = source.lstat()
        if source.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
            raise AppError(f"暂不处理链接或重解析项目：{source}", "unsupported")
        safe_name = _safe_arcname(name)
        if safe_name.casefold() in seen:
            raise AppError(f"来源包含同名项目：{safe_name}", "conflict")
        if len(seen) >= DEFAULT_MAX_ENTRIES:
            raise AppError("压缩包成员数量超过预算。", "budget")
        seen.add(safe_name.casefold())
        yield source, safe_name
        if stat.S_ISDIR(info.st_mode):
            for child in sorted(source.iterdir(), key=lambda item: item.name):
                yield from walk(child, f"{safe_name}/{child.name}")
        elif not stat.S_ISREG(info.st_mode):
            raise AppError(f"暂不处理这种文件：{source}", "unsupported")

    for source in sources:
        yield from walk(Path(source), Path(source).name)


def create_zip(sources: list[Path], destination: Path, password: str | None = None, encryption=None) -> Path:
    if destination.exists():
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
    if not sources:
        raise AppError("没有可压缩的文件。", "invalid")
    rows = list(_source_rows(sources))
    stage = destination.parent / f".gaocaozuo-archive-{uuid.uuid4().hex}"
    try:
        if password and encryption == "aes":
            import pyzipper

            with pyzipper.AESZipFile(stage, "x", compression=pyzipper.ZIP_DEFLATED, encryption=pyzipper.WZ_AES) as handle:
                handle.setpassword(password.encode("utf-8"))
                for source, name in rows:
                    handle.write(source, name)
        elif password:
            if sum(source.stat().st_size for source, _name in rows if source.is_file()) > 256 * 1024 * 1024:
                raise AppError("传统 ZIP 加密最多处理 256 MiB。可使用 AES 加密。", "budget")
            with stage.open("xb") as handle:
                files = [(name + "/", b"") if source.is_dir() else (name, source.read_bytes()) for source, name in rows]
                handle.write(build_zip(files, password))
        else:
            with zipfile.ZipFile(stage, "x", compression=zipfile.ZIP_DEFLATED) as handle:
                for source, name in rows:
                    handle.write(source, name)
        _commit_file(stage, destination)
    finally:
        stage.unlink(missing_ok=True)
    return destination


def _commit_file(stage: Path, destination: Path) -> None:
    try:
        os.link(stage, destination)
    except FileExistsError as exc:
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict") from exc
    except OSError:
        if os.name == "nt":
            os.rename(stage, destination)
        else:
            raise


def split_file(path: Path, part_bytes: int) -> list[Path]:
    if part_bytes < 64 * 1024:
        raise AppError("分卷不能小于 64 KiB。", "invalid")
    count = (path.stat().st_size + part_bytes - 1) // part_bytes
    if count > 999:
        raise AppError("最多生成 999 个分卷。", "budget")
    targets = [path.with_name(f"{path.name}.{number:03d}") for number in range(1, count + 1)]
    committed = []
    with path.open("rb") as source:
        try:
            for target in targets:
                with target.open("xb") as output:
                    committed.append(target)
                    remaining = part_bytes
                    while remaining and (chunk := source.read(min(remaining, 1024 * 1024))):
                        output.write(chunk)
                        remaining -= len(chunk)
        except OSError as exc:
            for target in committed:
                target.unlink(missing_ok=True)
            raise AppError("无法写入分卷，已移除本次新建的分卷。", "conflict") from exc
    return committed


def create_7z(sources: list[Path], destination: Path, password: str | None = None, solid: bool = True, split_mb: int | None = None) -> Path:
    import py7zr

    if not sources:
        raise AppError("没有可压缩的文件。", "invalid")
    if split_mb is not None and not 1 <= int(split_mb) <= 4096:
        raise AppError("分卷大小须为 1 至 4096 MiB。", "invalid")
    rows = list(_source_rows(sources))
    if not solid and len(rows) > 512:
        raise AppError("非固实 7Z 最多接受 512 个成员。", "budget")
    stage = destination.parent / f".gaocaozuo-archive-{uuid.uuid4().hex}"
    try:
        options = {"password": password, "header_encryption": bool(password)}
        if solid:
            with py7zr.SevenZipFile(stage, "x", **options) as handle:
                for source, name in rows:
                    handle.write(source, name)
        else:
            for index, (source, name) in enumerate(rows):
                with py7zr.SevenZipFile(stage, "x" if index == 0 else "a", **options) as handle:
                    handle.write(source, name)
        if split_mb:
            parts = split_file(stage, int(split_mb) * 1024 * 1024)
            installed = []
            try:
                for index, part in enumerate(parts, 1):
                    target = destination.with_name(f"{destination.name}.{index:03d}")
                    _commit_file(part, target)
                    installed.append(target)
            except (AppError, OSError):
                for target in installed:
                    target.unlink(missing_ok=True)
                raise
            finally:
                for part in parts:
                    part.unlink(missing_ok=True)
            return installed[0]
        _commit_file(stage, destination)
        return destination
    finally:
        stage.unlink(missing_ok=True)


def archive_parts(path: Path):
    path = Path(path)
    suffix = path.suffix.casefold()
    if suffix in {".zip", ".7z"}:
        sources = [path]
        base = path
    elif suffix.isascii() and suffix[1:].isdigit() and len(suffix) == 4 and path.with_suffix("").suffix.casefold() in {".zip", ".7z"}:
        base = path.with_suffix("")
        components = sorted(entry for entry in path.parent.iterdir()
                            if re.fullmatch(re.escape(base.name) + r"\.[0-9]{3}", entry.name, flags=re.I))
        sources = []
        for index, component in enumerate(components, 1):
            if component.suffix != f".{index:03d}":
                raise AppError("压缩分卷不连续或缺少第一卷。", "missing")
            sources.append(component)
    else:
        raise AppError("可预览和解压 ZIP、7Z 及它们的连续数字分卷。", "unsupported")
    if not sources:
        raise AppError("找不到压缩包。", "missing")
    for source in sources:
        if not source.is_file() or source.is_symlink() or getattr(source.lstat(), "st_file_attributes", 0) & 0x400:
            raise AppError("压缩包或分卷不是普通文件。", "unsafe")
    return base, sources


def archive_digest(path: Path) -> str:
    _base, sources = archive_parts(path)
    digest = hashlib.sha256()
    for source in sources:
        with source.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


@contextmanager
def _archive_input(path):
    base, sources = archive_parts(path)
    if sources == [base]:
        yield base.suffix.lower(), base
        return
    import tempfile

    with tempfile.TemporaryFile() as joined:
        if sum(part.stat().st_size for part in sources) > DEFAULT_MAX_BYTES:
            raise AppError("压缩分卷总尺寸超过预算。", "budget")
        for part in sources:
            with part.open("rb") as source:
                shutil.copyfileobj(source, joined, length=1024 * 1024)
        joined.seek(0)
        yield base.suffix.lower(), getattr(joined, "file", joined)


def _seven_rows(handle, max_entries, max_bytes):
    rows = []
    used = 0
    names = set()
    for entry in handle.list():
        if len(rows) >= max_entries or not (entry.is_directory or entry.is_file) or entry.is_symlink:
            raise AppError("7Z 成员数量超过预算，或包含链接及特殊文件。", "unsafe")
        name = _safe_arcname(entry.filename.rstrip("/"))
        if name.casefold() in names:
            raise AppError(f"压缩包内名称冲突：{name}", "conflict")
        names.add(name.casefold())
        size = entry.uncompressed or 0
        used += size
        if size < 0 or used > max_bytes:
            raise AppError("7Z 展开内容超过当前安全预算。", "budget")
        rows.append((entry.filename, name, size, entry.is_directory))
    return rows


def _seven_error(exc, password):
    from py7zr import exceptions

    if isinstance(exc, exceptions.PasswordRequired) or (password and isinstance(exc, (exceptions.CrcError, exceptions.Bad7zFile, ValueError, EOFError))):
        return AppError("需要密码或密码不正确。", "password")
    return AppError("7Z 压缩包已损坏，或使用了当前不支持的压缩方法。", "invalid")


def inspect_archive(path: Path, password=None):
    with _archive_input(path) as (suffix, source):
        if suffix == ".zip":
            return inspect_zip(source, password)
        import py7zr

        try:
            with py7zr.SevenZipFile(source, "r", password=password) as handle:
                return [{"name": original, "size": size, "directory": directory}
                        for original, _name, size, directory in _seven_rows(handle, DEFAULT_MAX_ENTRIES, DEFAULT_MAX_BYTES)]
        except AppError:
            raise
        except Exception as exc:
            raise _seven_error(exc, password) from exc


def extract_archive(path, destination, password=None, members=None, *, max_entries=DEFAULT_MAX_ENTRIES, max_bytes=DEFAULT_MAX_BYTES, deadline=None):
    with _archive_input(path) as (suffix, source):
        if suffix == ".zip":
            return extract_zip(source, destination, password, members, max_entries, max_bytes, deadline)
        return _extract_7z(source, destination, password, members, max_entries, max_bytes, deadline)


def _extract_7z(source, destination, password, members, max_entries, max_bytes, deadline):
    from py7zr import SevenZipFile
    from py7zr.io import Py7zIO, WriterFactory

    class Target(Py7zIO):
        def __init__(self, path, size):
            self.path, self.limit = path, size
            self.position = 0
            with path.open("xb"):
                pass

        def write(self, data):
            if self.position + len(data) > self.limit or (deadline and time.monotonic() > deadline):
                raise AppError("7Z 解压超过大小或时间预算。", "budget")
            with self.path.open("r+b") as output:
                output.seek(self.position)
                count = output.write(data)
            self.position += count
            return count

        def read(self, size=None):
            with self.path.open("rb") as output:
                output.seek(self.position)
                data = output.read(-1 if size is None else size)
            self.position += len(data)
            return data

        def seek(self, offset, whence=0):
            with self.path.open("rb") as output:
                output.seek(self.position)
                self.position = output.seek(offset, whence)
            return self.position

        def flush(self):
            pass

        def size(self):
            return self.path.stat().st_size

    class Factory(WriterFactory):
        def __init__(self, allowed):
            self.allowed = allowed

        def create(self, filename):
            name = _safe_arcname(filename)
            if name not in self.allowed:
                raise AppError("7Z 请求了清单以外的成员。", "unsafe")
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            return Target(path, self.allowed[name])

    destination = Path(destination)
    if destination.exists():
        raise AppError(f"已存在同名项目，未覆盖：{destination}", "conflict")
    stage = destination.parent / f".gaocaozuo-extract-{uuid.uuid4().hex}"
    stage.mkdir()
    try:
        try:
            with SevenZipFile(source, "r", password=password) as handle:
                rows = _seven_rows(handle, max_entries, max_bytes)
                selected = set(members) if members is not None else None
                wanted = [(original, name, size, directory) for original, name, size, directory in rows
                          if selected is None or original in selected or name in selected]
                files = {name: size for _original, name, size, directory in wanted if not directory}
                for _original, name, _size, directory in wanted:
                    if directory:
                        (stage / name).mkdir(parents=True, exist_ok=True)
                handle.extract(targets=[original for original, _name, _size, directory in wanted if not directory], factory=Factory(files))
                for name, size in files.items():
                    if (stage / name).stat().st_size != size:
                        raise AppError(f"7Z 成员大小与清单不同：{name}", "invalid")
        except AppError:
            raise
        except Exception as exc:
            raise _seven_error(exc, password) from exc
        os.rename(stage, destination)
        return destination
    finally:
        if stage.is_dir():
            shutil.rmtree(stage, ignore_errors=True)
