"""settings.json / receipts.json。损坏、过新或目录不空却没有主设置时不覆盖。"""

from __future__ import annotations

import hashlib
import json
import os
import uuid
from pathlib import Path

from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError
from gaocaozuo.version import SCHEMA_VERSION

DEFAULT_FAVORITES = [
    "new.text",
    "path.copy",
    "archive.create",
    "window.leftHalf",
    "window.rightHalf",
    "clipboard.show",
]
DEFAULT_TEMPLATES = [
    {"id": "tpl-markdown", "name": "Markdown", "filename": "未命名.md", "content": "# 新文档\n\n"},
    {"id": "tpl-csv", "name": "CSV 表格", "filename": "未命名.csv", "content": "名称,数值,备注\n"},
    {"id": "tpl-json", "name": "JSON", "filename": "未命名.json", "content": "{\n}\n"},
]
DEFAULT_EXCLUDED = [
    "com.apple.keychainaccess",
    "com.agilebits.onepassword7",
    "com.1password.1password",
    "com.bitwarden.desktop",
]
MANAGED_KEYS = {
    "appearance",
    "language",
    "showMenuBarIcon",
    "playNewFileSound",
    "statusBarLeftClick",
    "favorites",
    "folders",
    "templates",
    "snippets",
    "workflows",
    "clipboardEnabled",
    "clipboardDays",
    "clipboardLimit",
    "clipboardExcludedApps",
    "loginAtStartup",
    "windowDragEnabled",
    "windowSnapEnabled",
    "localLock",
    "cleanerDurationSeconds",
    "inputPaused",
}


def default_data_dir() -> Path:
    if os.name == "nt":
        root = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
    else:
        root = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(root) / "GaoSeries" / "GaoCaoZuo"


def default_settings() -> dict:
    return {
        "schema": SCHEMA_VERSION,
        "appearance": "system",
        "language": "system",
        "showMenuBarIcon": True,
        "playNewFileSound": False,
        "statusBarLeftClick": "panel",
        "favorites": list(DEFAULT_FAVORITES),
        "folders": [],
        "templates": [dict(item) for item in DEFAULT_TEMPLATES],
        "snippets": [],
        "workflows": [
            {
                "id": "workflow-read",
                "name": "左右阅读",
                "steps": [{"id": "step-left", "actionID": "window.leftHalf", "argument": ""}],
            }
        ],
        "clipboardEnabled": False,
        "clipboardDays": 7,
        "clipboardLimit": 200,
        "clipboardExcludedApps": list(DEFAULT_EXCLUDED),
        "loginAtStartup": False,
        "windowDragEnabled": False,
        "windowSnapEnabled": False,
        "localLock": {
            "schema": 1,
            "enabled": False,
            "idleSeconds": 300,
            "warningSeconds": 15,
            "action": "lockScreen",
        },
        "cleanerDurationSeconds": 180,
        "inputPaused": False,
    }


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reject_secrets(value: dict) -> None:
    for key in value:
        if str(key).lower() in {"password", "pin", "secret", "credential"}:
            raise AppError("闲置策略不保存密码，也不自动解锁。", "invalid")


def validate_settings(raw: dict) -> None:
    if not isinstance(raw, dict) or raw.get("schema") != SCHEMA_VERSION:
        raise AppError("设置来自更新版本或无效版本，已保留原资料并停止写入。", "newer")
    lock = raw.get("localLock", {"schema": 1, "enabled": False, "idleSeconds": 300, "warningSeconds": 15, "action": "lockScreen"})
    if not isinstance(lock, dict):
        raise AppError("闲置策略格式无效，已停止写入。", "invalid")
    _reject_secrets(lock)
    if lock.get("schema", 1) != 1:
        raise AppError("闲置策略格式过新或无效，已停止执行并保留原配置。", "newer")
    idle = lock.get("idleSeconds", 300)
    warning = lock.get("warningSeconds", 15)
    if not isinstance(idle, (int, float)) or not isinstance(warning, (int, float)):
        raise AppError("闲置时限须为 30 秒至 24 小时，执行前提醒须为 5 至 120 秒。", "invalid")
    if not (30 <= float(idle) <= 86400) or not (5 <= float(warning) <= 120):
        raise AppError("闲置时限须为 30 秒至 24 小时，执行前提醒须为 5 至 120 秒。", "invalid")
    if lock.get("action", "lockScreen") not in {"lockScreen", "screenSaver"}:
        raise AppError("闲置策略动作无效，已停止写入。", "invalid")
    cleaner = raw.get("cleanerDurationSeconds", 180)
    if not isinstance(cleaner, int) or not (30 <= cleaner <= 180):
        raise AppError("清洁模式时限无效，已保留资料并停止写入。", "invalid")
    migrations = raw.get("desktopMigrationIDs", [])
    if migrations is not None:
        if not isinstance(migrations, list) or len(migrations) > 128 or len(set(migrations)) != len(migrations):
            raise AppError("桌面迁移依据无效，已停止写入。", "invalid")
    days = raw.get("clipboardDays", 7)
    limit = raw.get("clipboardLimit", 200)
    if not isinstance(days, int) or not (1 <= days <= 3650):
        raise AppError("剪贴板保留天数无效，已停止写入。", "invalid")
    if not isinstance(limit, int) or not (1 <= limit <= 5000):
        raise AppError("剪贴板条数上限无效，已停止写入。", "invalid")


class JsonDocument:
    """一个 JSON 对象文件。schema 不是 1、解析失败或读取后被改动时停止写入。"""

    def __init__(self, path: Path, empty: dict):
        self.path = path
        self.empty = empty
        self.raw: dict | None = None
        self.digest: str | None = None
        self.status = "missing"
        self.notice = ""
        self.load()

    def load(self) -> None:
        self.raw = None
        self.digest = None
        if not self.path.exists():
            self.status = "missing"
            self.notice = f"还没有 {self.path.name}。"
            return
        try:
            data = self.path.read_bytes()
        except OSError:
            self.status = "corrupt"
            self.notice = f"无法读取 {self.path.name}，已停止写入。"
            return
        self.digest = _digest(data)
        try:
            parsed = json.loads(data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            self.status = "corrupt"
            self.notice = f"{self.path.name} 无法解析，已保留原文件并停止写入。"
            return
        if not isinstance(parsed, dict) or not isinstance(parsed.get("schema"), int):
            self.status = "corrupt"
            self.notice = f"{self.path.name} 缺少 schema，已保留原文件并停止写入。"
            return
        if parsed["schema"] != SCHEMA_VERSION:
            self.status = "newer" if parsed["schema"] > SCHEMA_VERSION else "corrupt"
            self.notice = f"{self.path.name} 来自更新版本或无效版本，已保留原资料并停止写入。"
            return
        self.raw = parsed
        self.status = "ready"
        self.notice = ""

    @property
    def writable(self) -> bool:
        return self.status in {"ready", "missing"}

    def create_if_missing(self) -> dict:
        if self.status == "ready":
            return self.raw or {}
        if self.status != "missing":
            raise AppError(self.notice, self.status)
        self.raw = json.loads(json.dumps(self.empty))
        self._write()
        return self.raw

    def replace(self, raw: dict) -> dict:
        if self.status not in {"ready", "missing"}:
            raise AppError(self.notice, self.status)
        if not isinstance(raw, dict) or raw.get("schema") != SCHEMA_VERSION:
            raise AppError("拒绝写入无效资料。", "invalid")
        self.raw = raw
        self._write()
        return self.raw

    def _write(self) -> None:
        if self.path.exists():
            current = _digest(self.path.read_bytes())
            if self.digest is not None and current != self.digest:
                raise AppError(f"{self.path.name} 在读取后已变化，已停止写入。", "conflict")
        payload = (json.dumps(self.raw, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        atomic_replace(self.path, payload)
        self.digest = _digest(self.path.read_bytes())
        self.status = "ready"
        self.notice = ""


class Store:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.settings_doc = JsonDocument(self.directory / "settings.json", default_settings())
        self.receipts_doc = JsonDocument(
            self.directory / "receipts.json",
            {"schema": SCHEMA_VERSION, "records": []},
        )
        self._inspect_settings()

    def _inspect_settings(self) -> None:
        if self.settings_doc.status != "missing":
            if self.settings_doc.status == "ready":
                try:
                    validate_settings(self.settings_doc.raw or {})
                except AppError as exc:
                    self.settings_doc.status = exc.code if exc.code in {"newer", "invalid"} else "corrupt"
                    self.settings_doc.notice = exc.message
                    self.settings_doc.raw = None
            return
        extras = [p for p in self.directory.iterdir() if p.name not in {".DS_Store"} and not p.name.startswith(".")]
        if extras:
            self.settings_doc.status = "foreign"
            self.settings_doc.notice = "资料目录已有文件但没有 settings.json，已停止写入，不会用空白设置覆盖。"

    @property
    def status(self) -> str:
        return self.settings_doc.status

    @property
    def notice(self) -> str:
        return self.settings_doc.notice

    @property
    def settings(self) -> dict | None:
        return self.settings_doc.raw

    def create_settings(self) -> dict:
        if self.settings_doc.status == "foreign":
            raise AppError(self.settings_doc.notice, "foreign")
        if self.settings_doc.status == "ready":
            return self.settings_doc.raw or {}
        if self.settings_doc.status != "missing":
            raise AppError(self.settings_doc.notice, self.settings_doc.status)
        raw = default_settings()
        validate_settings(raw)
        return self.settings_doc.replace(raw)

    def update_settings(self, changes: dict) -> dict:
        if self.settings_doc.status != "ready" or self.settings_doc.raw is None:
            raise AppError(self.notice or "设置尚未创建或不能写入。", self.status)
        raw = self.settings_doc.raw
        for key, value in changes.items():
            if key not in MANAGED_KEYS:
                raise AppError(f"这个字段由原有资料保留，Windows 版不从这里改写：{key}", "invalid")
            if key == "localLock" and isinstance(value, dict):
                _reject_secrets(value)
            raw[key] = value
        validate_settings(raw)
        self.settings_doc.replace(raw)
        return raw

    def toggle_favorite(self, action_id: str) -> list[str]:
        raw = self._ready()
        favorites = list(raw.get("favorites") or [])
        if action_id in favorites:
            favorites = [item for item in favorites if item != action_id]
        else:
            favorites.append(action_id)
        raw["favorites"] = favorites
        self.settings_doc.replace(raw)
        return favorites

    def _ready(self) -> dict:
        if self.settings_doc.status != "ready" or self.settings_doc.raw is None:
            raise AppError(self.notice or "设置不可用。", self.status)
        return self.settings_doc.raw

    def clipboard_enabled(self) -> bool:
        raw = self.settings
        return bool(raw and raw.get("clipboardEnabled"))

    def append_receipts(self, records: list[dict]) -> list[dict]:
        if self.receipts_doc.status not in {"ready", "missing"}:
            raise AppError(self.receipts_doc.notice, self.receipts_doc.status)
        if self.receipts_doc.status == "missing":
            self.receipts_doc.create_if_missing()
        raw = self.receipts_doc.raw or {"schema": SCHEMA_VERSION, "records": []}
        raw.setdefault("records", [])
        if not isinstance(raw["records"], list):
            raise AppError("恢复记录格式无效，已停止写入。", "corrupt")
        raw["records"].extend(records)
        self.receipts_doc.replace(raw)
        return records

    def receipts(self) -> list[dict]:
        if self.receipts_doc.status == "missing":
            return []
        if self.receipts_doc.status != "ready" or self.receipts_doc.raw is None:
            raise AppError(self.receipts_doc.notice, self.receipts_doc.status)
        records = self.receipts_doc.raw.get("records") or []
        if not isinstance(records, list):
            raise AppError("恢复记录格式无效。", "corrupt")
        return records

    def new_id(self) -> str:
        return str(uuid.uuid4())
