"""把设置、文件、压缩、剪贴板、窗口和截图接到同一套动作上。"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaocaozuo.archive import ExtractBatch, create_7z, create_zip, extract_zip, inspect_zip, seven_zip, split_file
from gaocaozuo.catalog import GROUPS, UNAVAILABLE, find_action, search_actions
from gaocaozuo.clipboard import ClipboardBook
from gaocaozuo.errors import AppError
from gaocaozuo.features import Handoff, SnippetLibrary, import_rules, run_workflow, shortcut_conflicts
from gaocaozuo.files import (
    apply_renames,
    create_directory,
    create_file,
    fingerprint,
    name_lines,
    path_lines,
    rename_preview,
    sha256,
    transfer,
    undo,
    unique_child,
    validate_directory,
)
from gaocaozuo.images import blank_office, encode_bmp, encode_png, load_image, scale
from gaocaozuo.layout import LayoutTransaction, Rect, matches, restore_focus, snap_target, target_frame
from gaocaozuo.qr import encode as encode_qr
from gaocaozuo.qr import to_png
from gaocaozuo.screenshot import ScreenshotSession
from gaocaozuo.store import MANAGED_KEYS, Store
from gaocaozuo.system import FakeSystem, IdlePolicy, SystemGateway, UnavailableSystem
from gaocaozuo.version import VERSION_LABEL

MEDIA = {"volumeUp", "volumeDown", "mute", "playPause", "nextTrack", "previousTrack"}
STATE_WINDOWS = {"minimize", "minimizeAll", "unminimizeAll", "close", "toggleFullScreen", "nextWindow", "previousWindow"}


class MemoryVault:
    def __init__(self):
        self.data: dict[str, str] = {}

    def put(self, account: str, secret: str) -> None:
        self.data[account] = secret

    def get(self, account: str) -> str | None:
        return self.data.get(account)


class App:
    def __init__(self, directory: Path, system=None, window_lister=None, vault=None):
        self.store = Store(directory)
        self.directory = Path(directory)
        self.clipboard = ClipboardBook(self.directory, self.store)
        self.snippets = SnippetLibrary(self.directory / "Snippets" / "library.json")
        self.handoff = Handoff()
        self.screenshots = ScreenshotSession(self.directory)
        self.system = SystemGateway(system if system is not None else (UnavailableSystem() if os.name != "nt" else _windows_system()))
        self.idle = IdlePolicy((self.store.settings or {}).get("localLock") or {"enabled": False})
        self.window_lister = window_lister or (lambda: [])
        self.vault = vault or MemoryVault()
        self.extract_batch = ExtractBatch()
        self.layout = LayoutTransaction()
        self.saved_frames: dict[str, Rect] = {}
        self.selection: list[str] = []
        self.last_message = ""

    def snapshot(self) -> dict:
        settings = self.store.settings
        public = None
        preserved: list[str] = []
        if settings:
            public = {key: settings.get(key) for key in ["schema", *sorted(MANAGED_KEYS)] if key in settings or key == "schema"}
            public["schema"] = settings.get("schema")
            preserved = sorted(key for key in settings if key not in MANAGED_KEYS and key != "schema")
        enabled = self.store.clipboard_enabled()
        return {
            "version": VERSION_LABEL,
            "name": "搞操作",
            "status": self.store.status,
            "notice": self.store.notice,
            "settings": public,
            "preservedKeys": preserved,
            "groups": [{"id": key, "title": title} for key, title in GROUPS],
            "favorites": list((settings or {}).get("favorites") or []),
            "workflows": list((settings or {}).get("workflows") or []),
            "snippets": list((self.snippets.raw or {}).get("snippets") or []) if self.snippets.status == "ready" else [],
            "clipboardEnabled": enabled,
            "clipboard": self.clipboard.items if enabled else [],
            "clipboardReads": self.clipboard.read_attempts,
            "paste": self._paste_public(),
            "receipts": _safe_receipts(self.store),
            "permissions": self.permissions(),
            "selection": list(self.selection),
            "message": self.last_message,
            "sevenZip": seven_zip() is not None,
            "awake": self.system.awake,
            "idle": {"state": self.idle.state, "enabled": bool(self.idle.config.get("enabled"))},
            "pins": self.screenshots.pins(),
        }

    def permissions(self) -> dict:
        return {
            "accessibility": {"status": "not-applicable", "detail": "Windows 没有辅助功能开关。窗口移动失败会直接说明，不会记为成功。"},
            "inputMonitoring": {"status": "not-registered", "detail": "未注册全局键盘钩子。快捷键保存在规则里，可在操作面板执行。"},
            "finderExtension": {"status": "not-installed", "detail": "没有写入资源管理器右键菜单。可以把路径粘到操作面板。"},
            "clipboardHistory": {"status": "enabled" if self.store.clipboard_enabled() else "disabled", "detail": "历史默认关闭，关闭时不读取历史文件。"},
            "screenCapture": {"status": "explicit-only", "detail": "只有按下捕获并确认后才采集，不保存未确认的画面。"},
            "automation": {"status": "not-applicable", "detail": "终端和资源管理器只在对应按钮确认后启动。"},
        }

    def create_settings(self) -> dict:
        created = self.store.create_settings()
        self.idle.apply_config(created.get("localLock") or {"enabled": False})
        self.clipboard = ClipboardBook(self.directory, self.store)
        return created

    def update_settings(self, changes: dict) -> dict:
        if self.store.settings is None:
            raise AppError(self.store.notice or "设置不可用。", self.store.status)
        if "clipboardEnabled" in changes and changes["clipboardEnabled"] and not self.store.clipboard_enabled():
            self.store.settings["clipboardEnabled"] = True
            try:
                self.clipboard = ClipboardBook(self.directory, self.store)
            except AppError:
                self.store.settings["clipboardEnabled"] = False
                self.clipboard = ClipboardBook(self.directory, self.store)
                raise
        updated = self.store.update_settings(changes)
        if "localLock" in changes:
            self.idle.apply_config(updated.get("localLock") or {"enabled": False})
        if "clipboardEnabled" in changes and not changes["clipboardEnabled"]:
            self.clipboard = ClipboardBook(self.directory, self.store)
        return updated

    def search(self, query: str) -> list[dict]:
        extra = []
        for workflow in (self.store.settings or {}).get("workflows") or []:
            extra.append(
                {
                    "id": "workflow.run." + workflow["id"],
                    "title": workflow["name"],
                    "detail": "组合操作",
                    "section": "workflows",
                    "keywords": "",
                    "files": False,
                    "available": True,
                    "unavailableReason": None,
                }
            )
        return search_actions(query, extra)

    def perform(self, action_id: str, payload: dict | None = None) -> dict:
        payload = payload or {}
        if action_id.startswith("workflow.run."):
            workflow_id = action_id.split(".", 2)[2]
            return self.run_workflow(workflow_id, payload)
        action = find_action(action_id)
        if action and action.get("unavailableReason"):
            raise AppError(action["unavailableReason"], "unavailable")
        if action_id in {"new.text", "new.markdown", "new.folder", "new.custom", "new.template", "file.new.docx", "file.new.xlsx", "file.new.pptx"}:
            return self._create(action_id, payload)
        if action_id == "path.copy":
            return {"text": path_lines(_paths(payload)), "copiedToSystemClipboard": False}
        if action_id == "name.copy":
            return {"text": name_lines(_paths(payload)), "copiedToSystemClipboard": False}
        if action_id == "hash.sha256":
            lines = [sha256(path) for path in _paths(payload)]
            return {"text": "\n".join(lines), "copiedToSystemClipboard": False}
        if action_id in {"files.copy", "files.move"}:
            records = transfer(_paths(payload), Path(payload["destination"]), action_id == "files.move")
            self.store.append_receipts(_stamp(records))
            return {"receipts": records}
        if action_id == "files.rename":
            if payload.get("plans"):
                records = apply_renames(payload["plans"])
                self.store.append_receipts(_stamp(records))
                return {"receipts": records}
            return {"plans": rename_preview(_paths(payload), payload.get("pattern") or "{name} {n:02}.{ext}", int(payload.get("start") or 1))}
        if action_id == "archive.create":
            return self._zip(payload, password=None)
        if action_id == "archive.7z":
            return self._seven(payload, solid=True)
        if action_id == "archive.custom":
            if payload.get("format") == "7z":
                return self._seven(payload, solid=bool(payload.get("solid", True)))
            result = self._zip(payload, password=payload.get("password"))
            if payload.get("splitMB"):
                parts = split_file(Path(result["path"]), int(payload["splitMB"]) * 1024 * 1024)
                result["parts"] = [str(part) for part in parts]
                result["splitFormat"] = "gaocaozuo-byte-parts"
            return result
        if action_id in {"archive.extract", "archive.extract.custom"}:
            return self._extract(payload)
        if action_id == "archive.list":
            return {"members": inspect_zip(Path(payload["path"]), payload.get("password"))}
        if action_id in {"images.png", "images.bmp", "images.convert"}:
            return self._convert(payload, "bmp" if action_id == "images.bmp" else payload.get("format") or "png")
        if action_id in {"text.qrcode", "text.qrcode.clipboard"}:
            return self._qr(payload)
        if action_id == "terminal.open":
            return self._terminal(payload)
        if action_id == "finder.reveal":
            return self._reveal(payload)
        if action_id == "folder.favorite.add":
            return self._favorite(payload)
        if action_id == "clipboard.copyplain":
            return self.clipboard.set_plain(payload.get("text") or "")
        if action_id == "clipboard.pasteplain":
            transaction = self.clipboard.begin_paste(
                payload.get("text") or "",
                bool(payload.get("sendEnter")),
                bool(payload.get("targetMatches", True)),
                payload.get("blocked"),
            )
            return {"id": transaction.id, "phase": transaction.phase, "automaticEnter": False}
        if action_id == "system.lock":
            return self.system.lock()
        if action_id == "system.sleep":
            return self.system.sleep()
        if action_id == "system.screenSaver":
            return self.system.screensaver()
        if action_id == "system.preventSleep.toggle":
            return self.system.set_awake(not self.system.awake)
        if action_id.startswith("system.") and action_id.split(".", 1)[1] in MEDIA:
            return self.system.media(action_id.split(".", 1)[1])
        if action_id.startswith("window."):
            return self._window(action_id.split(".", 1)[1], payload)
        if action_id == "windows.overview":
            return {"windows": self.window_lister(), "pixels": None}
        if action_id == "screenshot.capture":
            backend = payload.get("backend")
            if backend is None:
                backend = _capture_backend()
            return self.screenshots.capture(bool(payload.get("confirm")), backend)
        if action_id in {"screenshot.ocr.capture", "screenshot.ocr.clipboard"}:
            self.screenshots.ocr()
        if action_id.startswith("screenshot.translate"):
            self.screenshots.translate()
        if action_id == "screenshot.recording":
            self.screenshots.record()
        if action_id == "lock.settings":
            return {"idle": self.idle.tick(float(payload.get("idleSeconds") or 0), bool(payload.get("activity")), bool(payload.get("busy")))}
        raise AppError("这个动作还没有接到 Windows 执行入口。", "unavailable")

    def run_workflow(self, workflow_id: str, payload: dict) -> dict:
        workflows = (self.store.settings or {}).get("workflows") or []
        workflow = next((item for item in workflows if item.get("id") == workflow_id), None)
        if workflow is None:
            raise AppError("找不到组合操作。", "missing")

        def invoke(step):
            return self.perform(step.get("actionID"), {**payload, **({"argument": step.get("argument")} if step.get("argument") else {})})

        return run_workflow(workflow.get("steps") or [], invoke)

    def save_workflow(self, workflow: dict) -> dict:
        raw = self.store.settings
        if raw is None:
            raise AppError(self.store.notice or "设置不可用。", self.store.status)
        workflows = list(raw.get("workflows") or [])
        record = {
            "id": workflow.get("id") or str(uuid.uuid4()),
            "name": workflow.get("name") or "未命名组合",
            "steps": list(workflow.get("steps") or []),
        }
        replaced = False
        for index, existing in enumerate(workflows):
            if existing.get("id") == record["id"]:
                workflows[index] = record
                replaced = True
        if not replaced:
            workflows.append(record)
        raw["workflows"] = workflows
        self.store.settings_doc.replace(raw)
        return record

    def undo(self, receipt_ids: list[str]) -> dict:
        records = [item for item in self.store.receipts() if item.get("id") in set(receipt_ids)]
        if len(records) != len(set(receipt_ids)):
            raise AppError("有恢复记录找不到，已停止。", "missing")
        restored = undo(records, _trash)
        return {"restored": restored}

    def _create(self, action_id: str, payload: dict) -> dict:
        directory = validate_directory(Path(payload["directory"]))
        if action_id == "new.folder":
            path = unique_child(directory, "未命名文件夹", "")
            path = create_directory(directory, path.name)
        elif action_id == "new.text":
            path = unique_child(directory, "未命名", ".txt")
            path = create_file(directory, path.name, "")
        elif action_id == "new.markdown":
            path = unique_child(directory, "未命名", ".md")
            path = create_file(directory, path.name, "# 新文档\n\n")
        elif action_id == "new.custom":
            path = create_file(directory, payload["name"], payload.get("content") or "")
        elif action_id == "new.template":
            templates = (self.store.settings or {}).get("templates") or []
            template = next((item for item in templates if item.get("id") == payload.get("templateID")), None)
            if template is None and templates:
                template = templates[0]
            if template is None:
                raise AppError("没有可用模板。", "missing")
            path = unique_child(directory, Path(template["filename"]).stem, Path(template["filename"]).suffix)
            path = create_file(directory, path.name, template.get("content") or "")
        else:
            kind = {"file.new.docx": "docx", "file.new.xlsx": "xlsx", "file.new.pptx": "pptx"}[action_id]
            suffix, blob = blank_office(kind)
            path = unique_child(directory, "未命名", "." + suffix)
            if path.exists():
                raise AppError(f"已存在同名项目，未覆盖：{path}", "conflict")
            path.write_bytes(blob)
        record = {"id": str(uuid.uuid4()), "kind": "create", "source": None, "destination": str(path), "fingerprint": fingerprint(path)}
        self.store.append_receipts(_stamp([record]))
        return {"path": str(path), "receipt": record}

    def _zip(self, payload: dict, password: str | None) -> dict:
        sources = _paths(payload)
        destination = unique_child(sources[0].parent, sources[0].stem, ".zip")
        if password and payload.get("savePassword"):
            self.vault.put(sha256(sources[0]), password)
        create_zip(sources, destination, password)
        record = {"id": str(uuid.uuid4()), "kind": "create", "source": None, "destination": str(destination), "fingerprint": fingerprint(destination)}
        self.store.append_receipts(_stamp([record]))
        return {"path": str(destination), "encryption": "zipcrypto" if password else None}

    def _seven(self, payload: dict, solid: bool) -> dict:
        sources = _paths(payload)
        destination = unique_child(sources[0].parent, sources[0].stem, ".7z")
        create_7z(sources, destination, payload.get("password"), solid=solid, split_mb=payload.get("splitMB"))
        return {"path": str(destination), "solid": solid}

    def _extract(self, payload: dict) -> dict:
        archives = _paths(payload)

        def destination_for(archive: Path) -> Path:
            if payload.get("destination"):
                root = Path(payload["destination"])
                return unique_child(root, archive.stem, "")
            return unique_child(archive.parent, archive.stem, "")

        def password_for(archive: Path, incorrect: bool):
            if payload.get("password"):
                return payload.get("password")
            if payload.get("useSaved"):
                return self.vault.get(sha256(archive))
            return None

        limits = {}
        if payload.get("maxBytes"):
            limits["max_bytes"] = int(payload["maxBytes"])
        if payload.get("maxEntries"):
            limits["max_entries"] = int(payload["maxEntries"])
        if payload.get("members") and len(archives) == 1:
            destination = extract_zip(archives[0], destination_for(archives[0]), payload.get("password"), payload.get("members"), **limits)
            return {"items": [{"archive": str(archives[0]), "destination": str(destination), "skipped": False}]}
        return self.extract_batch.run(archives, destination_for, password_for, **limits)

    def _convert(self, payload: dict, fmt: str) -> dict:
        fmt = "jpeg" if fmt == "jpg" else fmt
        if fmt in {"jpeg", "heic", "tiff", "webp"}:
            raise AppError(UNAVAILABLE.get(f"images.{fmt}") or "这种图片格式不能编码。", "unavailable")
        if fmt not in {"png", "bmp"}:
            raise AppError("Windows 版可写 PNG 和 BMP。", "unsupported")
        outputs = []
        for source in _paths(payload):
            width, height, rgb = load_image(source)
            width, height, rgb = scale(width, height, rgb, payload.get("maxEdge"))
            blob = encode_png(width, height, rgb) if fmt == "png" else encode_bmp(width, height, rgb)
            destination = unique_child(source.parent, source.stem, "." + fmt)
            destination.write_bytes(blob)
            record = {"id": str(uuid.uuid4()), "kind": "convert", "source": str(source), "destination": str(destination), "fingerprint": fingerprint(destination)}
            self.store.append_receipts(_stamp([record]))
            outputs.append(str(destination))
        return {"paths": outputs}

    def _qr(self, payload: dict) -> dict:
        text = payload.get("text") or ""
        modules = encode_qr(text)
        blob = to_png(modules)
        directory = Path(payload["directory"]) if payload.get("directory") else None
        path = None
        if directory is not None:
            path = unique_child(validate_directory(directory), "二维码", ".png")
            path.write_bytes(blob)
        import base64

        return {"pngBase64": base64.b64encode(blob).decode("ascii"), "path": str(path) if path else None}

    def _terminal(self, payload: dict) -> dict:
        path = Path(payload["path"])
        if path.is_symlink() or not path.is_dir():
            raise AppError("请选择真实目录。", "invalid")
        command = ["cmd", "/K", "cd", "/d", str(path)]
        if not payload.get("launch"):
            return {"command": command, "launched": False}
        if os.name != "nt":
            raise AppError("当前系统不是 Windows，未启动终端。", "unavailable")
        import subprocess

        subprocess.Popen(command)
        return {"command": command, "launched": True}

    def _reveal(self, payload: dict) -> dict:
        path = Path(payload["path"])
        if not path.exists():
            raise AppError(f"找不到：{path}", "invalid")
        command = ["explorer", f"/select,{path}"]
        if not payload.get("launch"):
            return {"command": command, "launched": False}
        if os.name != "nt":
            raise AppError("当前系统不是 Windows，未打开资源管理器。", "unavailable")
        import subprocess

        subprocess.Popen(command)
        return {"command": command, "launched": True}

    def _favorite(self, payload: dict) -> dict:
        raw = self.store.settings
        if raw is None:
            raise AppError(self.store.notice or "设置不可用。", self.store.status)
        path = str(validate_directory(Path(payload["path"])))
        folders = list(raw.get("folders") or [])
        if any(item.get("path") == path for item in folders):
            raise AppError(f"已存在同名项目，未覆盖：{path}", "conflict")
        folders.append({"id": str(uuid.uuid4()), "name": Path(path).name, "path": path})
        raw["folders"] = folders
        self.store.settings_doc.replace(raw)
        return {"path": path}

    def _window(self, name: str, payload: dict) -> dict:
        if name in STATE_WINDOWS:
            backend = payload.get("backend")
            if backend is None or not hasattr(backend, name):
                raise AppError("此动作需要窗口状态操作，当前没有可确认的窗口后端，未伪造成功。", "unavailable")
            ok = getattr(backend, name)()
            if not ok:
                raise AppError("目标窗口拒绝了这个状态操作。", "rejected")
            return {"action": name, "exact": True}
        screens = [Rect(**item) for item in payload.get("screens") or [{"x": 0, "y": 0, "w": 1920, "h": 1080}]]
        current = Rect(**payload.get("frame") or {"x": 100, "y": 100, "w": 800, "h": 600})
        if name == "restore":
            saved = self.saved_frames.get(payload.get("windowID") or "default")
            if saved is None:
                raise AppError("没有可恢复的原位置记录。", "missing")
            requested = saved
            allow_constrained = False
        else:
            requested = target_frame(name, current, screens)
            allow_constrained = True
        if not payload.get("apply"):
            return {"requested": requested.as_dict(), "applied": False, "exact": False}
        backend = payload.get("backend")
        if backend is None:
            raise AppError("没有可确认的窗口后端，只计算了布局，没有移动窗口。", "unavailable")
        result = self.layout.execute(requested, current, screens[0], True, allow_constrained, backend)
        if result["exact"] and name != "restore":
            self.saved_frames[payload.get("windowID") or "default"] = current
        if name == "restore" and result["exact"]:
            self.saved_frames.pop(payload.get("windowID") or "default", None)
        result["applied"] = True
        return result

    def focus(self, target_pid: int, own_pid: int, frontmost, validate, raise_target, activate) -> dict:
        restore_focus(target_pid, own_pid, frontmost, validate, raise_target, activate)
        return {"raised": True}

    def snap(self, pointer_x: float, pointer_y: float, screens: list[dict]) -> dict | None:
        if not (self.store.settings or {}).get("windowSnapEnabled"):
            raise AppError("边缘吸附尚未开启，没有移动窗口。", "disabled")
        found = snap_target(pointer_x, pointer_y, [Rect(**item) for item in screens])
        if found is None:
            return None
        action, frame = found
        return {"action": action, "screen": frame.as_dict(), "applied": False}

    def rules(self) -> list[dict]:
        path = self.directory / "Input" / "rules.json"
        if not path.exists():
            return []
        import json

        parsed = json.loads(path.read_text(encoding="utf-8"))
        if parsed.get("schema") != 1:
            raise AppError("输入规则版本不受支持，已停止写入。", "newer")
        return list(parsed.get("rules") or [])

    def save_rules(self, rules: list[dict]) -> dict:
        conflicts = shortcut_conflicts(rules)
        if conflicts:
            raise AppError("快捷键与现有规则冲突，未保存。", "conflict")
        import json

        from gaocaozuo.atomic import atomic_replace

        path = self.directory / "Input" / "rules.json"
        preserved: dict = {}
        if path.exists():
            try:
                existing = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                raise AppError("输入规则无法读取，已停止写入。", "corrupt") from exc
            if not isinstance(existing, dict) or existing.get("schema") != 1:
                raise AppError("输入规则版本不受支持，已停止写入。", "newer")
            preserved = {key: value for key, value in existing.items() if key not in {"schema", "rules"}}
        path.parent.mkdir(parents=True, exist_ok=True)
        document = {"schema": 1, "rules": rules, **preserved}
        atomic_replace(path, (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode())
        return {"rules": rules}

    def import_input(self, remote: list[dict], tombstones: list[str] | None = None) -> dict:
        return import_rules(self.rules(), remote, tombstones or [])

    def _paste_public(self) -> dict | None:
        transaction = self.clipboard.transaction
        if transaction is None:
            return None
        return {
            "id": transaction.id,
            "phase": transaction.phase,
            "sendEnterRequested": transaction.send_enter_requested,
            "enterWasSubmitted": transaction.enter_was_submitted,
        }


def _paths(payload: dict) -> list[Path]:
    values = payload.get("paths") or payload.get("files") or []
    if not values:
        raise AppError("请先选择文件。", "invalid")
    return [Path(value) for value in values]


def _stamp(records: list[dict]) -> list[dict]:
    moment = datetime.now(timezone.utc).isoformat()
    return [{**record, "date": moment} for record in records]


def _safe_receipts(store: Store) -> list[dict]:
    if store.receipts_doc.status == "missing":
        return []
    if store.receipts_doc.status != "ready":
        return []
    try:
        return store.receipts()
    except AppError:
        return []


def _trash(path: Path) -> None:
    if path.is_dir():
        import shutil

        shutil.rmtree(path)
    else:
        path.unlink()


def _windows_system():
    from gaocaozuo.platform_win import WindowsSystem

    return WindowsSystem()


def _capture_backend():
    if os.name != "nt":
        def fail():
            raise AppError("当前系统没有可用的屏幕采集接口。", "unavailable")

        return fail
    from gaocaozuo.platform_win import capture_screen

    return capture_screen


def layout_matches(actual: dict, requested: dict) -> bool:
    return matches(Rect(actual["x"], actual["y"], actual["width"], actual["height"]), Rect(requested["x"], requested["y"], requested["width"], requested["height"]))
