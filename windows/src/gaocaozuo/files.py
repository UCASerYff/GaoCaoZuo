"""文件操作不静默覆盖。收据是内容指纹，不保证文件仍在。"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import uuid
from pathlib import Path

from gaocaozuo.errors import AppError

_NUMBER = re.compile(r"\{n:(0?)([1-9][0-9]?)\}")
_INVALID = set('\\/:*?"<>|')


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _lstat(path: Path):
    try:
        return path.lstat()
    except OSError as exc:
        raise AppError(f"无法读取：{path}", "invalid") from exc


def ensure_real(path: Path) -> None:
    info = _lstat(path)
    if info.st_mode & 0o170000 == 0o120000:
        raise AppError(f"暂不处理符号链接、特殊文件或无法读取的项目：{path}", "unsupported")


def validate_name(name: str) -> str:
    if not name or name in {".", ".."} or any(ch in _INVALID or ord(ch) < 32 for ch in name):
        raise AppError(f"名称无效：{name}", "invalid")
    if name.endswith(" ") or name.endswith("."):
        raise AppError(f"名称不能以空格或句点结尾：{name}", "invalid")
    if len(name) > 255:
        raise AppError("名称超过 255 个字符。", "invalid")
    return name


def validate_directory(directory: Path) -> Path:
    directory = Path(directory)
    if not directory.exists() or not directory.is_dir():
        raise AppError(f"目录不存在：{directory}", "invalid")
    ensure_real(directory)
    return directory


def fingerprint(path: Path) -> str:
    path = Path(path)
    ensure_real(path)
    info = path.lstat()
    mode = info.st_mode & 0o777
    if path.is_file():
        return f"file:{_sha256_file(path)}:{mode}"
    if not path.is_dir():
        raise AppError(f"暂不处理符号链接、特殊文件或无法读取的项目：{path}", "unsupported")
    entries: list[Path] = []

    def walk(directory: Path) -> None:
        children = sorted(directory.iterdir(), key=lambda item: item.name)
        if len(children) > 100_000:
            raise AppError("单个目录超过 10 万项预算。", "invalid")
        for child in children:
            ensure_real(child)
            if not child.is_file() and not child.is_dir():
                raise AppError(f"暂不处理符号链接、特殊文件或无法读取的项目：{child}", "unsupported")
            entries.append(child)
            if len(entries) > 100_000:
                raise AppError("目录超过 10 万个项目的操作预算。", "invalid")
            if child.is_dir():
                walk(child)

    walk(path)
    digest = hashlib.sha256()
    digest.update(f"directory:{mode}\n".encode())
    root = str(path)
    for child in sorted(entries, key=lambda item: str(item)):
        child_mode = child.lstat().st_mode & 0o777
        relative = str(child)[len(root):]
        content = _sha256_file(child) if child.is_file() else "directory"
        line = f"{len(relative.encode())}:{relative}:{content}:{child_mode}\n"
        digest.update(line.encode())
    return "directory:" + digest.hexdigest()


def _absent(path: Path) -> None:
    if path.exists() or path.is_symlink():
        raise AppError(f"已存在同名项目，未覆盖：{path}", "conflict")


def _distinct(paths: list[Path]) -> None:
    seen: set[str] = set()
    for path in paths:
        key = str(path.resolve()) if path.exists() else str(path)
        if key in seen:
            raise AppError(f"目标路径重复，已停止：{path}", "conflict")
        seen.add(key)


def unique_child(directory: Path, stem: str, suffix: str) -> Path:
    validate_name(stem + suffix if suffix else stem)
    candidate = directory / f"{stem}{suffix}"
    number = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = directory / f"{stem} {number}{suffix}"
        number += 1
        if number > 10000:
            raise AppError("重名编号超过上限，已停止。", "invalid")
    return candidate


def create_file(directory: Path, name: str, content: str) -> Path:
    directory = validate_directory(directory)
    validate_name(name)
    destination = directory / name
    _absent(destination)
    destination.write_bytes(content.encode("utf-8"))
    return destination


def create_directory(directory: Path, name: str) -> Path:
    directory = validate_directory(directory)
    validate_name(name)
    destination = directory / name
    _absent(destination)
    destination.mkdir()
    return destination


def _inside(parent: Path, child: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def transfer(items: list[Path], directory: Path, move: bool) -> list[dict]:
    directory = validate_directory(directory)
    if not items:
        raise AppError("请先选择文件。", "invalid")
    sources = [Path(item) for item in items]
    for source in sources:
        if not source.exists():
            raise AppError(f"找不到：{source}", "invalid")
        ensure_real(source)
    destinations = [directory / source.name for source in sources]
    _distinct(destinations)
    fingerprints = []
    for source, destination in zip(sources, destinations):
        _absent(destination)
        src = source.resolve()
        dst = destination.resolve() if destination.exists() else destination
        if src == dst or _inside(src, directory) and source.is_dir():
            raise AppError("不能把文件夹复制或移动到自身内部。", "invalid")
        fingerprints.append(fingerprint(source))
    stage = None if move else directory / f".gaocaozuo-copy-{uuid.uuid4().hex}"
    completed: list[dict] = []
    if stage is not None:
        stage.mkdir()
    try:
        if stage is not None:
            for source in sources:
                staged = stage / source.name
                if source.is_dir():
                    shutil.copytree(source, staged, symlinks=False)
                else:
                    shutil.copy2(source, staged)
                if fingerprint(staged) != fingerprints[sources.index(source)]:
                    raise AppError(f"文件已发生变化，为保护资料无法继续：{source}", "changed")
            for destination in destinations:
                _absent(destination)
        for index, source in enumerate(sources):
            destination = destinations[index]
            if move:
                shutil.move(str(source), str(destination))
            else:
                shutil.move(str(stage / source.name), str(destination))
            record = {
                "id": str(uuid.uuid4()),
                "kind": "move" if move else "copy",
                "source": str(source),
                "destination": str(destination),
                "fingerprint": fingerprints[index],
            }
            completed.append(record)
            if fingerprint(destination) != fingerprints[index]:
                raise AppError(f"文件已发生变化，为保护资料无法继续：{destination}", "changed")
        return completed
    except Exception:
        residual = _rollback(completed)
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)
        if residual:
            paths = "\n".join(item["destination"] for item in residual)
            raise AppError(f"操作未完成，部分项目无法安全自动恢复，资料已保留。\n{paths}", "partial")
        raise
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def _rollback(records: list[dict]) -> list[dict]:
    residual = []
    for record in reversed(records):
        destination = Path(record["destination"])
        source = Path(record["source"]) if record.get("source") else None
        try:
            if not destination.exists():
                continue
            if fingerprint(destination) != record["fingerprint"]:
                residual.append(record)
                continue
            if record["kind"] in {"move", "rename"} and source is not None and not source.exists():
                shutil.move(str(destination), str(source))
            elif record["kind"] in {"copy", "create", "convert"}:
                if destination.is_dir():
                    shutil.rmtree(destination)
                else:
                    destination.unlink()
        except OSError:
            residual.append(record)
    return residual


def rename_preview(items: list[Path], pattern: str, start: int) -> list[dict]:
    if not items:
        raise AppError("请先选择文件。", "invalid")
    if start < 0:
        raise AppError("起始序号无效。", "invalid")
    plans = []
    for index, source in enumerate(items):
        source = Path(source)
        ensure_real(source)
        fingerprint(source)
        number = start + index
        name = pattern.replace("{name}", source.stem).replace("{ext}", source.suffix[1:]).replace("{n}", str(number))
        matches = list(_NUMBER.finditer(name))
        for match in reversed(matches):
            width = int(match.group(2))
            if width > 20:
                raise AppError("序号补零宽度须在 1–20 之间。", "invalid")
            value = str(number)
            padded = value.rjust(width, "0")
            name = name[: match.start()] + padded + name[match.end() :]
        if source.suffix == "" and pattern.endswith(".{ext}") and name.endswith("."):
            name = name[:-1]
        validate_name(name)
        destination = source.parent / name
        if destination != source:
            _absent(destination)
        plans.append({"id": str(uuid.uuid4()), "source": str(source), "destination": str(destination)})
    _distinct([Path(item["destination"]) for item in plans])
    return plans


def apply_renames(plans: list[dict]) -> list[dict]:
    sources = [Path(item["source"]) for item in plans]
    destinations = [Path(item["destination"]) for item in plans]
    _distinct(sources)
    _distinct(destinations)
    fingerprints: dict[str, str] = {}
    for plan in plans:
        source = Path(plan["source"])
        destination = Path(plan["destination"])
        if source == destination:
            continue
        if source.parent != destination.parent:
            raise AppError("批量改名不能更换文件所在目录。", "invalid")
        validate_name(destination.name)
        _absent(destination)
        fingerprints[plan["id"]] = fingerprint(source)
    receipts = []
    try:
        for plan in plans:
            digest = fingerprints.get(plan["id"])
            if digest is None:
                continue
            source = Path(plan["source"])
            destination = Path(plan["destination"])
            os.replace(source, destination)
            receipts.append(
                {
                    "id": str(uuid.uuid4()),
                    "kind": "rename",
                    "source": str(source),
                    "destination": str(destination),
                    "fingerprint": digest,
                }
            )
        return receipts
    except Exception as exc:
        residual = _rollback(receipts)
        if residual:
            raise AppError(f"操作未完成，部分项目无法安全自动恢复。{exc}", "partial") from exc
        raise


def undo(records: list[dict], trash) -> int:
    _distinct([Path(item["destination"]) for item in records])
    pending = []
    for record in records:
        destination = Path(record["destination"])
        if not destination.exists() and not destination.is_symlink():
            if record["kind"] in {"move", "rename"}:
                source = Path(record["source"])
                if fingerprint(source) != record["fingerprint"]:
                    raise AppError(f"文件已发生变化，为保护资料无法恢复：{source}", "changed")
            continue
        if fingerprint(destination) != record["fingerprint"]:
            raise AppError(f"文件已发生变化，为保护资料无法恢复：{destination}", "changed")
        if record["kind"] in {"move", "rename"}:
            source = record.get("source")
            if not source:
                raise AppError("恢复记录缺少原始路径。", "invalid")
            _absent(Path(source))
        pending.append(record)
    restored = 0
    try:
        for record in pending:
            destination = Path(record["destination"])
            if record["kind"] in {"move", "rename"}:
                source = Path(record["source"])
                shutil.move(str(destination), str(source))
                if fingerprint(source) != record["fingerprint"]:
                    raise AppError(f"文件已发生变化，为保护资料无法恢复：{source}", "changed")
            else:
                trash(destination)
            restored += 1
        return restored
    except AppError:
        raise
    except Exception as exc:
        total = len(pending)
        raise AppError(f"恢复中断：本次已完成 {restored}/{total} 项；请保留恢复记录，可重试其余项目。{exc}", "partial") from exc


def sha256(path: Path) -> str:
    path = Path(path)
    ensure_real(path)
    if not path.is_file():
        raise AppError(f"请选择文件：{path}", "invalid")
    return _sha256_file(path)


def path_lines(paths: list[Path]) -> str:
    return "\n".join(str(Path(path)) for path in paths)


def name_lines(paths: list[Path]) -> str:
    return "\n".join(Path(path).name for path in paths)
