"""剪贴板历史默认关闭。粘贴事务只在用户确认后结束，不定时恢复、不自动回车。"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError
from gaocaozuo.version import SCHEMA_VERSION

EDITABLE_ROLES = {"AXTextField", "AXTextArea", "AXComboBox", "Edit", "RichEdit"}


class PasteTransaction:
    def __init__(self, original_change_count: int, snapshot: dict, send_enter: bool):
        self.id = str(uuid.uuid4())
        self.original_change_count = original_change_count
        self.snapshot = json.loads(json.dumps(snapshot))
        self.send_enter_requested = send_enter
        self.phase = "preparing"
        self.temporary_change_count: int | None = None
        self.enter_was_submitted = False
        self.completion_was_attempted = False
        self.completion_succeeded = False

    def permits_temporary(self, change_count: int, target_matches: bool) -> bool:
        return (
            self.phase == "preparing"
            and self.temporary_change_count is None
            and self.original_change_count == change_count
            and target_matches
        )

    def installed_temporary(self, change_count: int) -> None:
        if self.phase != "preparing" or change_count == self.original_change_count:
            raise AppError("临时剪贴板状态无效，未发送粘贴。", "invalid")
        self.temporary_change_count = change_count
        self.phase = "waitingForTarget"

    def failed_before_submission(self) -> None:
        if self.phase in {"preparing", "waitingForTarget"}:
            self.phase = "failedBeforeSubmission"

    def permits_dispatch(self, change_count: int, target_matches: bool) -> bool:
        return self.phase == "waitingForTarget" and self.temporary_change_count == change_count and target_matches

    def submitted(self, change_count: int, target_matches: bool) -> None:
        if not self.permits_dispatch(change_count, target_matches):
            raise AppError("粘贴前目标或剪贴板已变化，未发送。", "changed")
        self.phase = "awaitingUser"

    def record_enter(self, role: str | None, editable: bool) -> None:
        if self.phase not in {"awaitingUser", "confirmed"}:
            raise AppError("粘贴事件尚未发送，请等待目标确认或取消。", "invalid")
        if not self.send_enter_requested or self.enter_was_submitted:
            raise AppError("这项请求没有待发送回车，或回车事件已发送。", "invalid")
        if role not in EDITABLE_ROLES or not editable:
            raise AppError("回车只发给仍可编辑的文本区域。", "invalid")
        self.enter_was_submitted = True

    def begin_completion(self) -> None:
        if self.phase not in {"awaitingUser", "confirmed"}:
            raise AppError("粘贴事件尚未发送，请等待目标确认或取消。", "invalid")
        if self.completion_was_attempted:
            raise AppError("插入确认记录已经处理过，不会自动重试或重复弹出堆栈。", "invalid")
        self.completion_was_attempted = True
        self.phase = "confirmed"

    def completed(self) -> None:
        if self.phase != "confirmed" or not self.completion_was_attempted or self.completion_succeeded:
            raise AppError("插入确认记录状态无效，未重复提交。", "invalid")
        self.completion_succeeded = True


def merge_parts(parts: list[dict]) -> list[dict]:
    allowed = {"text", "image", "file", "folder"}
    merged = []
    for part in parts:
        kind = part.get("kind")
        if kind not in allowed:
            raise AppError("堆栈只接受文字、图片、文件和文件夹。", "invalid")
        merged.append({"kind": kind, "text": part.get("text"), "path": part.get("path")})
    return merged


class ClipboardBook:
    def __init__(self, directory, store, reader=None):
        self.directory = directory
        self.store = store
        self.path = directory / "Clipboard" / "history.json"
        self.reader = reader or self.path.read_bytes
        self.items: list[dict] = []
        self.loaded = False
        self.read_attempts = 0
        self.change_count = 1
        self.snapshot = {"text": "", "parts": []}
        self.transaction: PasteTransaction | None = None
        self.stack: list[dict] = []
        if store.clipboard_enabled():
            self._load()

    def _load(self) -> None:
        self.read_attempts += 1
        if not self.path.exists():
            self.items = []
            self.loaded = True
            return
        try:
            data = self.reader()
            parsed = json.loads(data.decode("utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise AppError("剪贴板历史无法读取，已停止写入。", "corrupt") from exc
        if not isinstance(parsed, dict) or parsed.get("schema") != SCHEMA_VERSION or not isinstance(parsed.get("items"), list):
            raise AppError("剪贴板历史版本不受支持，已停止写入。", "newer")
        self.items = parsed["items"]
        self.loaded = True
        self._expire()

    def _expire(self) -> None:
        raw = self.store.settings or {}
        days = int(raw.get("clipboardDays") or 7)
        limit = int(raw.get("clipboardLimit") or 200)
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        kept = []
        for item in self.items:
            if item.get("pinned"):
                kept.append(item)
                continue
            try:
                moment = datetime.fromisoformat(item.get("date", ""))
            except ValueError:
                continue
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=timezone.utc)
            if moment >= cutoff:
                kept.append(item)
        pinned = [item for item in kept if item.get("pinned")]
        fresh = [item for item in kept if not item.get("pinned")]
        self.items = pinned + fresh[: max(0, limit - len(pinned))]

    def remember(self, text: str, source_app: str, kind: str = "text", parts: list[dict] | None = None) -> dict | None:
        if not self.store.clipboard_enabled():
            return None
        if not self.loaded:
            self._load()
        excluded = set((self.store.settings or {}).get("clipboardExcludedApps") or [])
        if source_app in excluded:
            return None
        item = {
            "id": str(uuid.uuid4()),
            "date": datetime.now(timezone.utc).isoformat(),
            "kind": kind,
            "title": text.splitlines()[0][:80] if text else kind,
            "text": text,
            "parts": parts or [],
            "pinned": False,
            "sourceApp": source_app,
        }
        self.items.insert(0, item)
        self._expire()
        self._save()
        return item

    def _save(self) -> None:
        if not self.store.clipboard_enabled():
            raise AppError("剪贴板历史未启用，不会写入。", "disabled")
        payload = (json.dumps({"schema": SCHEMA_VERSION, "items": self.items}, ensure_ascii=False, indent=2) + "\n").encode()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        atomic_replace(self.path, payload)

    def search(self, query: str) -> list[dict]:
        if not self.store.clipboard_enabled():
            return []
        q = query.strip().lower()
        rows = self.items
        if q:
            rows = [item for item in rows if q in (item.get("text") or "").lower() or q in (item.get("title") or "").lower()]
        return rows

    def set_plain(self, text: str) -> dict:
        self.change_count += 1
        self.snapshot = {"text": text, "parts": [{"kind": "text", "text": text}]}
        return {"changeCount": self.change_count, "text": text}

    def begin_paste(self, text: str, send_enter: bool, target_matches: bool, blocked: str | None = None) -> PasteTransaction:
        if blocked:
            raise AppError(blocked, "blocked")
        if self.transaction is not None and self.transaction.phase not in {"failedBeforeSubmission", "confirmed"}:
            raise AppError("还有一项粘贴等待核对。请先确认已插入或取消，不能连续覆盖原剪贴板。", "busy")
        if self.transaction is not None and self.transaction.phase == "confirmed" and not self.transaction.completion_succeeded:
            raise AppError("还有一项粘贴等待核对。请先确认已插入或取消，不能连续覆盖原剪贴板。", "busy")
        original = PasteTransaction(self.change_count, self.snapshot, send_enter)
        if not original.permits_temporary(self.change_count, target_matches):
            raise AppError("粘贴前目标或剪贴板已变化，未发送。", "changed")
        self.change_count += 1
        self.snapshot = {"text": text, "parts": [{"kind": "text", "text": text}]}
        original.installed_temporary(self.change_count)
        if not original.permits_dispatch(self.change_count, target_matches):
            original.failed_before_submission()
            self.snapshot = original.snapshot
            self.change_count += 1
            raise AppError("粘贴前目标或剪贴板已变化，未发送。", "changed")
        original.submitted(self.change_count, target_matches)
        self.transaction = original
        return original

    def confirm(self) -> dict:
        if self.transaction is None:
            raise AppError("没有等待核对的粘贴。", "invalid")
        self.transaction.begin_completion()
        if self.stack:
            merged = merge_parts(self.stack)
            self.snapshot = {"text": "\n".join(part.get("text") or part.get("path") or "" for part in merged), "parts": merged}
            self.change_count += 1
            self.stack = []
        self.transaction.completed()
        done = self.transaction
        self.transaction = None
        return {"id": done.id, "phase": done.phase, "enterSubmitted": done.enter_was_submitted}

    def cancel(self) -> dict:
        if self.transaction is None:
            raise AppError("没有等待核对的粘贴。", "invalid")
        self.snapshot = self.transaction.snapshot
        self.change_count += 1
        self.transaction = None
        self.stack = []
        return {"restored": True, "changeCount": self.change_count}

    def enter(self, role: str | None, editable: bool) -> dict:
        if self.transaction is None:
            raise AppError("没有等待核对的粘贴。", "invalid")
        self.transaction.record_enter(role, editable)
        return {"enterSubmitted": True, "automatic": False}

    def push_stack(self, parts: list[dict]) -> list[dict]:
        if self.transaction is None or self.transaction.phase != "awaitingUser":
            raise AppError("堆栈只在粘贴已发送、等待核对时准备，确认后才提交。", "invalid")
        self.stack = merge_parts(parts)
        return self.stack
