"""Verified archive edits from the Windows archive preview."""

from __future__ import annotations

import os
import shutil
import stat
import tempfile
import time
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import Path

from gaocaozuo.archive import _commit_file, _is_symlink, _member_name, _safe_arcname, extract_archive, zip_reader
from gaocaozuo.errors import AppError
from gaocaozuo.files import sha256

MIB = 1024 * 1024
MAX_ITEMS = 10_000
MAX_INPUT = 512 * MIB


def _identity(path: Path):
    if not path.is_absolute() or path.is_symlink() or path.parent.resolve() != path.parent:
        raise AppError("请选择本机的普通文件路径。", "unsafe")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or getattr(info, "st_file_attributes", 0) & 0x400:
        raise AppError("预览编辑仅接受常规单链接文件。", "unsafe")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def _fingerprint(path: Path):
    before = _identity(path)
    if before[2] > MAX_INPUT:
        raise AppError("压缩包超过预览编辑的 512 MiB 上限。", "budget")
    digest = sha256(path)
    if _identity(path) != before:
        raise AppError("压缩包在读取期间发生变化。", "changed")
    return before, digest


def _key(name):
    return unicodedata.normalize("NFC", name).casefold()


def _zip_members(path):
    import pyzipper
    import zipfile

    try:
        with zip_reader(path) as archive:
            rows = []
            for item in archive.infolist():
                if _is_symlink(item):
                    raise AppError("预览编辑不支持压缩包中的链接或特殊路径。", "unsafe")
                rows.append((_member_name(item), item.file_size, item.is_dir(), bool(item.flag_bits & 1)))
            return rows
    except (OSError, zipfile.BadZipFile, pyzipper.BadZipFile) as exc:
        raise AppError("无法读取 ZIP 的成员清单。", "invalid") from exc


def _seven_members(path, password):
    from lzma import LZMAError

    import py7zr
    from py7zr import exceptions

    def read(candidate):
        with py7zr.SevenZipFile(path, password=candidate) as archive:
            encrypted = archive.needs_password()
            rows = []
            for item in archive.list():
                if item.is_symlink or not (item.is_directory or item.is_file):
                    raise AppError("预览编辑不支持压缩包中的链接或特殊路径。", "unsafe")
                rows.append((_safe_arcname(item.filename.rstrip("/")), item.uncompressed or 0, item.is_directory,
                             encrypted and item.is_file))
            return rows

    try:
        try:
            return read(None)
        except exceptions.PasswordRequired:
            if not password:
                raise
            return read(password)
    except exceptions.PasswordRequired as exc:
        raise AppError("请输入当前压缩包的密码。", "password") from exc
    except (exceptions.ArchiveError, LZMAError, OSError, ValueError) as exc:
        raise AppError("不能读取 7Z 清单。请核对密码或原包。", "password" if password else "invalid") from exc


def _members(path, password):
    rows = _zip_members(path) if path.suffix.lower() == ".zip" else _seven_members(path, password)
    if not rows or len(rows) > MAX_ITEMS or sum(row[1] for row in rows) > MAX_INPUT or any(row[1] > 128 * MIB for row in rows):
        raise AppError("压缩包的成员或大小超过预览编辑预算。", "budget")
    tree = {}
    explicit = set()
    prefix_bytes = 0
    for name, _size, directory, _encrypted in rows:
        parts = name.split("/")
        if len(parts) > 64:
            raise AppError("压缩包目录过深。", "budget")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            identifier = _key(prefix)
            branch = index < len(parts) or directory
            if identifier not in tree:
                prefix_bytes += len(prefix.encode("utf-8"))
                tree[identifier] = prefix, branch
            elif tree[identifier] != (prefix, branch):
                raise AppError(f"压缩包成员名称冲突：{name}", "conflict")
        if identifier in explicit:
            raise AppError(f"压缩包含重复成员：{name}", "conflict")
        explicit.add(identifier)
    if len(tree) > 4000 or prefix_bytes > 4 * MIB:
        raise AppError("压缩包路径数量或字节数超限。", "budget")
    return rows


def _stage_file(source, target, expected):
    with source.open("rb") as original, target.open("xb") as copy:
        if _identity(source) != expected:
            raise AppError("文件在复制前已发生变化。", "changed")
        shutil.copyfileobj(original, copy, 1024 * 1024)
    if _identity(source) != expected or target.stat().st_size != expected[2]:
        raise AppError("文件在复制期间已发生变化。", "changed")


def _archive_members(root, path, rows, password):
    if path.suffix.lower() == ".zip":
        import pyzipper

        with pyzipper.AESZipFile(path, "x", compression=pyzipper.ZIP_DEFLATED,
                                 encryption=pyzipper.WZ_AES if password else None) as archive:
            if password:
                archive.setpassword(password.encode("utf-8"))
            for name, _size, _directory, _encrypted in rows:
                archive.write(root / name, name)
        return
    import py7zr

    with py7zr.SevenZipFile(path, "x", password=password, header_encryption=bool(password)) as archive:
        for name, _size, _directory, _encrypted in rows:
            archive.write(root / name, name)


def _replace_windows(original, candidate, displaced):
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.native_win import kernel

    replace = kernel("ReplaceFileW", w.BOOL, w.LPCWSTR, w.LPCWSTR, w.LPCWSTR, w.DWORD, w.LPVOID, w.LPVOID)
    if not replace(str(original), str(candidate), str(displaced) if displaced else None, 0, None, None):
        raise OSError(c.get_last_error(), "ReplaceFileW")


def _commit_original(original, candidate, expected, approved_digest):
    if os.name != "nt":
        raise AppError("当前会话不能执行 Windows 原件替换。", "unavailable")
    displaced = original.parent / f".gaocaozuo-{uuid.uuid4().hex}.held"
    newer = original.parent / f".gaocaozuo-{uuid.uuid4().hex}.held"
    try:
        _replace_windows(original, candidate, displaced)
        if _fingerprint(displaced) != expected or _fingerprint(original)[1] != approved_digest:
            raise AppError("保存阶段检测到压缩包变化。", "changed")
    except (AppError, OSError) as failure:
        if displaced.exists():
            try:
                if original.exists():
                    if _fingerprint(original)[1] != approved_digest:
                        raise OSError("concurrent replacement")
                    _replace_windows(original, displaced, newer)
                    if _fingerprint(newer)[1] == approved_digest:
                        newer.unlink()
                else:
                    os.rename(displaced, original)
            except (AppError, OSError) as exc:
                raise AppError(f"原件发生并发变化，已保留可恢复文件：{displaced}", "recovery") from exc
        if isinstance(failure, AppError):
            raise failure
        raise AppError("Windows 拒绝替换压缩包；请关闭正在使用原包的程序。", "conflict") from failure
    displaced.unlink()


@dataclass(frozen=True)
class Inspection:
    path: Path
    original: tuple
    rows: list
    expires: float


class ArchiveEditor:
    def __init__(self):
        self.sessions: dict[str, Inspection] = {}

    def preview(self, path: Path, password=None):
        if path.suffix.lower() not in {".zip", ".7z"}:
            raise AppError("只支持编辑未分卷的 ZIP 和 7Z。", "unsupported")
        original = _fingerprint(path)
        rows = _members(path, password)
        if _fingerprint(path) != original:
            raise AppError("压缩包在预览期间发生变化，请重新打开。", "changed")
        session = uuid.uuid4().hex
        now = time.monotonic()
        self.sessions = {key: value for key, value in self.sessions.items() if value.expires > now}
        if len(self.sessions) >= 16:
            self.sessions.pop(next(iter(self.sessions)))
        self.sessions[session] = Inspection(path, original, rows, now + 900)
        return {"previewID": session, "encrypted": any(row[3] for row in rows), "members": self._public(rows)}

    @staticmethod
    def _public(rows):
        return [{"name": name, "size": size, "directory": directory, "encrypted": encrypted}
                for name, size, directory, encrypted in rows]

    def save(self, payload):
        preview_id = payload.get("previewID")
        review = self.sessions.get(preview_id)
        mode = payload.get("mode")
        if payload.get("confirm") is not True or mode not in {"replace", "copy"}:
            raise AppError("请选择保存原件或另存新副本并明确确认。", "confirmation")
        if review is None or time.monotonic() > review.expires:
            raise AppError("预览已过期，请重新打开压缩包。", "expired")
        original, expected = review.path, review.original
        if _fingerprint(original) != expected:
            raise AppError("压缩包在预览后发生变化，请重新预览。", "changed")
        additions, removals = payload.get("add") or [], payload.get("remove") or []
        remove_hidden = payload.get("removeHidden") is True
        if not isinstance(additions, list) or not isinstance(removals, list) or len(additions) > 64 or len(removals) > MAX_ITEMS:
            raise AppError("所选成员超过预览编辑预算。", "budget")
        if not additions and not removals and not remove_hidden:
            raise AppError("请选择新增、移除或清理隐藏成员。", "invalid")
        target = original if mode == "replace" else Path(payload["destination"])
        if (not target.is_absolute() or target.suffix.lower() != original.suffix.lower()
                or not target.parent.is_dir() or target.parent.resolve() != target.parent):
            raise AppError("请选择与原包同格式的本机目标文件。", "invalid")
        _safe_arcname(target.name)
        if mode == "copy" and os.path.lexists(target):
            raise AppError(f"已存在同名项目，未覆盖：{target}", "conflict")
        password = payload.get("password") if any(row[3] for row in review.rows) else None
        if any(row[3] for row in review.rows) and not password:
            raise AppError("请输入压缩包密码；编辑将保留加密。", "password")
        removed = {_safe_arcname(name) for name in removals}
        if not removed.issubset({row[0] for row in review.rows}):
            raise AppError("所选移除项已变化，请重新预览。", "changed")

        def kept(row):
            name = row[0]
            return not any(name == member or name.startswith(member + "/") for member in removed) and not (
                remove_hidden and any(part.startswith(".") or part == "__MACOSX" for part in name.split("/")))

        rows = [row for row in review.rows if kept(row)]
        selected = {name for name, _size, _directory, _encrypted in rows}
        with tempfile.TemporaryDirectory(prefix=".gaocaozuo-edit-", dir=target.parent) as temp:
            workspace = Path(temp)
            staged = workspace / ("source" + original.suffix.lower())
            _stage_file(original, staged, expected[0])
            if sha256(staged) != expected[1]:
                raise AppError("压缩包在复制期间发生变化。", "changed")
            contents = workspace / "contents"
            try:
                extract_archive(staged, contents, password, max_entries=MAX_ITEMS, max_bytes=MAX_INPUT,
                                deadline=time.monotonic() + 60)
            except (ValueError, OSError, RuntimeError) as exc:
                raise AppError("无法验证原压缩包，请核对密码及原包。", "password" if password else "invalid") from exc
            busy = {_key(name.split("/", 1)[0]) for name in selected}
            total = 0
            for item in additions:
                source = Path(item)
                name = _safe_arcname(source.name)
                identity = _identity(source)
                total += identity[2]
                if _key(name) in busy:
                    raise AppError(f"新增文件与压缩包成员重名：{name}", "conflict")
                if total > 256 * MIB or identity[2] > 128 * MIB:
                    raise AppError("新增附件超过预览编辑预算。", "budget")
                busy.add(_key(name))
                new_file = workspace / ("addition-" + uuid.uuid4().hex)
                _stage_file(source, new_file, identity)
                if (contents / name).exists():
                    if (contents / name).is_dir():
                        shutil.rmtree(contents / name)
                    else:
                        (contents / name).unlink()
                os.rename(new_file, contents / name)
                rows.append((name, identity[2], False, bool(password)))
            if not rows:
                raise AppError("编辑后仍需保留至少一个成员。", "invalid")
            candidate = workspace / ("result" + target.suffix.lower())
            _archive_members(contents, candidate, rows, password)
            verified = _members(candidate, password)
            if {(row[0], row[1], row[2]) for row in verified} != {(row[0], row[1], row[2]) for row in rows} or (
                    password and any(not encrypted for _name, _size, directory, encrypted in verified if not directory)):
                raise AppError("编辑结果未通过成员或加密核验，原包保留。", "verification")
            recovered = extract_archive(candidate, workspace / "verify", password, max_entries=MAX_ITEMS, max_bytes=MAX_INPUT,
                                        deadline=time.monotonic() + 60)
            if any(sha256(contents / name) != sha256(recovered / name) for name, _size, directory, _encrypted in rows if not directory):
                raise AppError("编辑结果的内容与校验值不符。", "verification")
            digest = sha256(candidate)
            if _fingerprint(original) != expected:
                raise AppError("压缩包在保存前发生变化。", "changed")
            if mode == "replace":
                _commit_original(original, candidate, expected, digest)
            else:
                _commit_file(candidate, target)
        self.sessions.pop(preview_id, None)
        return {"path": str(target), "mode": mode, "sha256": digest, "members": self._public(verified)}
