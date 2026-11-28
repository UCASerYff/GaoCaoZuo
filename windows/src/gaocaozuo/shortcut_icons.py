"""Local mascot icon library and reversible icon-only shortcut changes."""

from __future__ import annotations

import base64
import hashlib
import io
import os
import stat
from pathlib import Path

from PIL import Image

from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError
from gaocaozuo.resources import asset_dir
from gaocaozuo.shortcut_link import ShellLink
from gaocaozuo.store import JsonDocument


ROLE_NAMES = {"chatgpt": "ChatGPT", "claude": "Claude", "gemini": "Gemini", "grok": "Grok", "deepseek": "DeepSeek",
              "kimi": "Kimi", "glm": "GLM", "qwen": "Qwen"}
ORIGINAL_ROLES = tuple(ROLE_NAMES)[:5]
ROLE_MATCHES = {role: (role,) for role in ROLE_NAMES} | {"glm": ("glm", "智谱", "zhipu"), "qwen": ("qwen", "千问", "tongyi")}
MAX_LNK = 1024 * 1024
MAX_ICON = 8 * 1024 * 1024
MAX_LIST = 400
MAX_BATCH = 100


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read(path: Path, maximum: int) -> bytes:
    with path.open("rb") as handle:
        data = handle.read(maximum + 1)
    if not data or len(data) > maximum:
        raise AppError("文件大小超出可读取范围。", "invalid")
    return data


def _ico_image(content: bytes) -> Image.Image:
    try:
        with Image.open(io.BytesIO(content), formats=["ICO"]) as icon:
            if not all(1 <= size <= 256 for size in icon.size):
                raise ValueError
            return icon.convert("RGBA")
    except (ValueError, SyntaxError, Image.DecompressionBombError, OSError) as exc:
        raise AppError("请选择有效的 ICO 图标文件。", "invalid-icon") from exc


def _data_url(image: Image.Image | None) -> str:
    if image is None:
        return ""
    image.thumbnail((96, 96), Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def _key(path: Path) -> str:
    return os.path.normcase(str(path))


class ShortcutIcons:
    def __init__(self, directory: Path):
        self.directory = directory / "ShortcutIcons"
        self.document = JsonDocument(self.directory / "state.json", {"schema": 1, "roles": {}, "links": {}})

    def _read_document(self) -> dict:
        doc = self.document
        doc.load()
        data = doc.raw if doc.status == "ready" else doc.empty
        if not doc.writable or not isinstance(data.get("roles"), dict) or not isinstance(data.get("links"), dict):
            raise AppError("换装记录无法读取，已停止修改快捷方式。", "corrupt")
        return data

    @staticmethod
    def _platform():
        if os.name != "nt":
            raise AppError("此功能需要 Windows 工作台。", "unavailable")
        from gaocaozuo import shortcut_platform_win

        return shortcut_platform_win

    def dispatch(self, endpoint: str, payload: dict) -> dict:
        platform = self._platform()
        data = self._read_document()
        if endpoint == "list":
            return self.list(data, platform, payload.get("added", []))
        if endpoint == "preview":
            return self.preview(data, platform, payload.get("path"))
        if endpoint == "import":
            role = payload.get("role")
            if role not in ROLE_NAMES:
                raise AppError("请选择要导入的角色。", "invalid")
            path = platform.source_path(payload.get("path", ""), {".ico"}, MAX_ICON)
            return self._import(data, {role: _read(path, MAX_ICON)})
        if endpoint == "originals":
            return self._import_originals(data, platform, payload.get("path"))
        if endpoint in {"apply", "restore"}:
            if payload.get("confirm") is not True:
                raise AppError("请确认要修改的快捷方式。", "confirmation")
            return self._batch(data, platform, payload.get("items"), endpoint == "restore")
        raise AppError("没有这个换装动作。", "not-found")

    def _icon_file(self, digest: str) -> Path:
        return self.directory.resolve() / "Icons" / (digest + ".ico")

    def _bundled_path(self, role: str) -> Path | None:
        return asset_dir() / "mascots" / (role + ".png") if role in ROLE_NAMES else None

    def _existing_icon(self, data: dict, role: str) -> tuple[Path, bytes] | tuple[None, None]:
        digest = data["roles"].get(role)
        if not isinstance(digest, str) or len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            return None, None
        path = self._icon_file(digest)
        try:
            content = _read(path, MAX_ICON)
            if _digest(content) == digest:
                return path, content
        except (AppError, OSError):
            pass
        return None, None

    def _roles(self, data: dict) -> list[dict]:
        roles = []
        for role, label in ROLE_NAMES.items():
            local_preview = ""
            _, content = self._existing_icon(data, role)
            bundled = self._bundled_path(role)
            if content:
                try:
                    local_preview = _data_url(_ico_image(content))
                except AppError:
                    pass
            hd_preview = "/mascots/" + bundled.name if bundled and bundled.is_file() else ""
            roles.append({"id": role, "label": label, "hdPreview": hd_preview, "localPreview": local_preview})
        return roles

    def _write_icon(self, content: bytes) -> tuple[Path, str]:
        if len(content) > MAX_ICON:
            raise AppError("图标超过 8 MiB。", "invalid")
        _ico_image(content)
        digest = _digest(content)
        path = self._icon_file(digest)
        if path.exists():
            if _digest(_read(path, MAX_ICON)) != digest:
                raise AppError("已保存的角色图标已变化，请重新导入。", "changed")
        else:
            atomic_replace(path, content)
        return path, digest

    def _role_path(self, data: dict, role: str, variant: str) -> Path:
        local, _ = self._existing_icon(data, role)
        if variant == "local" and local is not None:
            return local
        bundled = self._bundled_path(role)
        if bundled is None or not bundled.is_file():
            if local is not None:
                return local
            raise AppError("请先导入所选角色的本地图标。", "missing-icon")
        with Image.open(bundled, formats=["PNG"]) as source:
            icon = source.convert("RGBA")
            icon.thumbnail((256, 256), Image.Resampling.LANCZOS)
            output = io.BytesIO()
            icon.save(output, format="ICO", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
        return self._write_icon(output.getvalue())[0]

    def _import(self, data: dict, entries: dict[str, bytes]) -> dict:
        for content in entries.values():
            _ico_image(content)
        for role, content in entries.items():
            _, data["roles"][role] = self._write_icon(content)
        self.document.replace(data)
        return {"roles": self._roles(data), "imported": list(entries)}

    def _import_originals(self, data: dict, platform, value) -> dict:
        path = platform.local_path(value)
        if path.suffix.casefold() == ".exe" or (path / "AI-Mascot-Icons.exe").is_file():
            from gaocaozuo.mascot_original_pack import load_v1_icons

            entries = {role: content for role, content in load_v1_icons(path).items() if role in ORIGINAL_ROLES}
        elif path.is_dir():
            entries = {}
            for role in ORIGINAL_ROLES:
                for directory in (path, path / "assets" / "icons", path / "icons"):
                    file = directory / (ROLE_NAMES[role] + ".ico")
                    if file.is_file():
                        entries[role] = _read(platform.source_path(str(file), {".ico"}, MAX_ICON), MAX_ICON)
                        break
        else:
            raise AppError("请选择原版程序或含角色 ICO 的本机目录。", "invalid")
        if not entries:
            raise AppError("没有找到原版的五款角色图标。", "missing-icon")
        return self._import(data, entries)

    @staticmethod
    def _read_link(platform, value) -> tuple[Path, bytes, ShellLink]:
        path = platform.source_path(value, {".lnk"}, MAX_LNK)
        raw = _read(path, MAX_LNK)
        return path, raw, ShellLink(raw)

    def list(self, data: dict, platform, added) -> dict:
        if not isinstance(added, list) or len(added) > MAX_BATCH or not all(isinstance(path, str) for path in added):
            raise AppError("手动加入的快捷方式数量或格式无效。", "invalid")
        rows = {}
        skipped = 0

        def add(value: str, source: str) -> None:
            nonlocal skipped
            if len(rows) >= MAX_LIST:
                return
            try:
                path, raw, link = self._read_link(platform, value)
            except (AppError, OSError):
                skipped += 1
                return
            key = _key(path)
            if key in rows:
                if rows[key]["source"] == "added" and source != "added":
                    rows[key]["source"] = source
                return
            receipt = data["links"].get(key)
            observed = _digest(raw)
            owned = isinstance(receipt, dict) and observed in (receipt.get("before"), receipt.get("after")) and observed != receipt.get("originalHash")
            name = path.stem
            words = name.casefold()
            suggested = next((role for role, labels in ROLE_MATCHES.items() if any(word in words for word in labels)), "")
            rows[key] = {"path": str(path), "name": name, "source": source, "iconPath": link.icon_path,
                         "iconIndex": link.icon_index, "suggested": suggested, "managed": owned,
                         "changed": isinstance(receipt, dict) and not owned and observed != receipt.get("originalHash")}

        for value in added:
            add(value, "added")
        for value in data["links"]:
            add(value, "added")
        for source, folder in platform.user_folders():
            try:
                folder = platform.local_path(str(folder))
            except AppError:
                continue
            for directory, children, names in os.walk(folder, followlinks=False):
                children[:] = [name for name in children if self._regular_directory(Path(directory) / name)]
                if source == "desktop":
                    children.clear()
                for name in names:
                    if name.casefold().endswith(".lnk"):
                        add(str(Path(directory) / name), source)
                if len(rows) >= MAX_LIST:
                    break
        return {"items": list(rows.values()), "roles": self._roles(data), "skipped": skipped, "limited": len(rows) >= MAX_LIST}

    @staticmethod
    def _regular_directory(path: Path) -> bool:
        try:
            data = path.lstat()
            return stat.S_ISDIR(data.st_mode) and not getattr(data, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
        except OSError:
            return False

    def preview(self, data: dict, platform, value) -> dict:
        path, raw, link = self._read_link(platform, value)
        record = data["links"].get(_key(path))
        if isinstance(record, dict) and _digest(raw) in (record.get("before"), record.get("after")):
            original = link.restored(record.get("originalIcon"))
            if _digest(original) != record.get("originalHash"):
                raise AppError("无法确认要恢复的原图标，快捷方式未修改。", "changed")
            link = ShellLink(original)
        source = os.path.expandvars(link.icon_path or link.local_target)
        if source and not Path(source).is_absolute():
            source = str(path.parent / source)
        image = None
        if source:
            try:
                file = platform.source_path(source, {".ico", ".exe", ".dll", ".cpl", ".icl"}, 512 * 1024 * 1024)
                image = _ico_image(_read(file, MAX_ICON)) if file.suffix.casefold() == ".ico" else platform.extracted_icon(file, link.icon_index)
            except (AppError, OSError):
                pass
        return {"preview": _data_url(image)}

    def _batch(self, data: dict, platform, items, restore: bool) -> dict:
        if not isinstance(items, list) or not 1 <= len(items) <= MAX_BATCH or not all(isinstance(item, dict) for item in items):
            raise AppError("请选择 1 至 100 个快捷方式。", "invalid")
        result = []
        role_files = {}
        seen = set()
        for item in items:
            value = item.get("path", "")
            try:
                path, before, link = self._read_link(platform, value)
                key = _key(path)
                if key in seen:
                    continue
                seen.add(key)
                if restore:
                    self._restore(data, platform, path, before, link)
                else:
                    role = item.get("role")
                    variant = item.get("variant", "hd")
                    if role not in ROLE_NAMES or variant not in {"hd", "local"}:
                        raise AppError("请为快捷方式选择角色。", "invalid")
                    choice = (role, variant)
                    if choice not in role_files:
                        role_files[choice] = self._role_path(data, role, variant)
                    self._apply(data, platform, path, before, link, role_files[choice])
                result.append({"path": str(path), "ok": True})
            except (AppError, OSError, ValueError, TypeError) as exc:
                error = exc.message if isinstance(exc, AppError) else "无法读取或修改此快捷方式。"
                result.append({"path": value, "ok": False, "error": error})
        return {"items": result}

    def _apply(self, data: dict, platform, path: Path, before: bytes, link: ShellLink, icon: Path) -> None:
        key = _key(path)
        observed = _digest(before)
        prior = data["links"].get(key)
        if prior is not None and (not isinstance(prior, dict) or observed not in (prior.get("before"), prior.get("after"))):
            raise AppError("快捷方式已被其他程序修改，已跳过。", "changed")
        after = link.with_icon(icon)
        if after == before:
            return
        original_hash = prior["originalHash"] if prior else observed
        original = prior["originalIcon"] if prior else link.icon_metadata()
        if _digest(ShellLink(after).restored(original)) != original_hash:
            raise AppError("未能确认图标以外的快捷方式信息。", "changed")
        written = _digest(after)
        record = {"originalHash": original_hash, "originalIcon": original, "before": observed, "after": written}
        data["links"][key] = record
        self.document.replace(data)
        platform.replace_shortcut(path, before, after)
        platform.notify_shortcut(path)
        record["before"] = written
        self.document.replace(data)

    def _restore(self, data: dict, platform, path: Path, before: bytes, link: ShellLink) -> None:
        key = _key(path)
        record = data["links"].get(key)
        if not isinstance(record, dict):
            raise AppError("未找到由搞操作保存的原图标。", "missing")
        observed = _digest(before)
        original_hash = record.get("originalHash")
        if observed != original_hash:
            if observed not in (record.get("before"), record.get("after")):
                raise AppError("快捷方式已被其他程序修改，已跳过。", "changed")
            restored = link.restored(record.get("originalIcon"))
            if _digest(restored) != original_hash:
                raise AppError("无法确认要恢复的原图标，快捷方式未修改。", "changed")
            platform.replace_shortcut(path, before, restored)
            platform.notify_shortcut(path)
        data["links"].pop(key)
        self.document.replace(data)
