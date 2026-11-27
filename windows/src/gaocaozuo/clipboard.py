"""剪贴板历史默认关闭。粘贴事务只在用户确认后结束，不定时恢复、不自动回车。"""

from __future__ import annotations

import base64
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
    def __init__(self, directory, store, reader=None, read_history=True):
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
        self.read_blocked = not read_history
        if read_history and store.clipboard_enabled():
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
        if any(not isinstance(item, dict) for item in parsed["items"]):
            raise AppError("剪贴板历史条目无法读取，原资料已保留。", "corrupt")
        self.document = parsed
        self.items = [item if isinstance(item.get("id"), str) and item["id"] else
                      dict(item, id=str(uuid.uuid5(uuid.NAMESPACE_OID, f"{index}:{json.dumps(item, sort_keys=True)}")))
                      for index, item in enumerate(parsed["items"])]
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
        if self.read_blocked:
            raise AppError("历史资料无法安全读取，原文件已保留。", "corrupt")
        if not self.loaded:
            self._load()
        excluded = set((self.store.settings or {}).get("clipboardExcludedApps") or [])
        if source_app.casefold() in {str(value).casefold() for value in excluded}:
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
        self.replace_items([item, *self.items])
        return item

    def _save(self) -> None:
        if not self.store.clipboard_enabled():
            raise AppError("剪贴板历史未启用，不会写入。", "disabled")
        if self.read_blocked:
            raise AppError("历史资料无法安全读取，原文件已保留。", "corrupt")
        document = dict(getattr(self, "document", {}), schema=SCHEMA_VERSION, items=self.items)
        payload = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        atomic_replace(self.path, payload)
        self.document = document

    def replace_items(self, items: list[dict]) -> None:
        previous = self.items
        self.items = items
        try:
            self._expire()
            self._save()
        except (AppError, OSError, ValueError, TypeError):
            self.items = previous
            raise

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


class NativeClipboardBook(ClipboardBook):
    def __init__(self, directory, store, native, desktop, read_history=True):
        super().__init__(directory, store, read_history=read_history)
        self.native = native
        self.desktop = desktop
        self.sequence = native.sequence() if read_history and store.clipboard_enabled() else None
        self.original = None
        self.temporary = None
        self.multiple = []
        self.stack_capture_count = 0
        self.target = None
        self.focus = None
        self.notice = ""

    def observe(self) -> None:
        if not self.store.clipboard_enabled() or self.read_blocked:
            self.sequence = None
            return
        sequence = self.native.sequence()
        if sequence == self.sequence:
            return
        previous, self.sequence = self.sequence, sequence
        if previous is None or self.transaction is not None:
            return
        try:
            value = self.native.observe(sequence, (self.store.settings or {}).get("clipboardExcludedApps") or [])
            if value:
                self._remember_native(value)
        except (AppError, OSError, ValueError):
            self.notice = "有一项内容无法安全收集。"

    def _remember_native(self, value: dict) -> None:
        directory = self.directory / "Clipboard" / "Images"
        parts = list(value["parts"])
        text = value["text"]
        path = None
        if text:
            parts.insert(0, {"kind": "text", "text": text})
        rich = {key: base64.b64encode(data).decode("ascii") for key, data in value["rich"].items() if data}
        if value["png"]:
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / (str(uuid.uuid4()) + ".png")
            atomic_replace(path, value["png"])
            parts.append({"kind": "image", "path": str(path.resolve())})
        try:
            kind = "text" if text else ("image" if path else "file")
            item = {
                "id": str(uuid.uuid4()), "date": datetime.now(timezone.utc).isoformat(), "kind": kind,
                "title": text.splitlines()[0][:80] if text else ("图片" if path else "文件"),
                "text": text, "parts": parts, "pinned": False, "sourceApp": value["source"], "windowsRich": rich,
            }
            if not self.items or any(item[key] != self.items[0].get(key) for key in ("text", "parts", "windowsRich")):
                self.replace_items([item, *self.items])
        except (AppError, OSError):
            if path:
                path.unlink(missing_ok=True)
            raise

    def replace_items(self, items: list[dict]) -> None:
        previous = self.items
        super().replace_items(items)
        def managed(rows):
            return {part.get("path") for item in rows for part in (item.get("parts") or [])
                    if isinstance(part, dict) and part.get("kind") == "image" and isinstance(part.get("path"), str)}
        asset_dir = (self.directory / "Clipboard" / "Images").resolve()
        for removed in managed(previous) - managed(self.items):
            path = Path(removed)
            if path.parent == asset_dir and path.suffix.lower() == ".png":
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    self.notice = "历史已更新，有一张本机图片暂时无法清理。"

    def set_plain(self, text: str) -> dict:
        if self.transaction is not None:
            raise AppError("请先处理等待核对的粘贴。", "busy")
        self.sequence = self.native.replace(self.native.plain_formats(text))
        return {"changeCount": self.sequence, "text": text, "copiedToSystemClipboard": True}

    def formats_for(self, item: dict, temporary=False):
        parts = item.get("parts") or ([{"kind": "text", "text": item["text"]}] if item.get("text") else [])
        formats = self.native.part_formats(parts, temporary=temporary)
        for name, value in (item.get("windowsRich") or {}).items():
            if name in {"HTML Format", "Rich Text Format"} and isinstance(value, str) and len(value) <= 3_000_000:
                try:
                    formats[self.native.named[name]] = base64.b64decode(value, validate=True)
                except ValueError as exc:
                    raise AppError("保存的剪贴板富文本已损坏。", "corrupt") from exc
        return formats

    def copy_item(self, item: dict) -> dict:
        if self.transaction is not None:
            raise AppError("请先处理等待核对的粘贴。", "busy")
        self.sequence = self.native.replace(self.formats_for(item))
        return {"copied": True, "changeCount": self.sequence}

    def copy_image(self, png: bytes) -> dict:
        if self.transaction is not None:
            raise AppError("请先处理等待核对的粘贴。", "busy")
        import io
        from PIL import Image

        if len(png) > 32 * 1024 * 1024:
            raise AppError("图像超过系统剪贴板大小限制。", "budget")
        with Image.open(io.BytesIO(png)) as image, io.BytesIO() as bitmap:
            if image.width * image.height > 16_000_000:
                raise AppError("图像超过系统剪贴板像素限制。", "budget")
            image.convert("RGB").save(bitmap, "BMP")
            self.sequence = self.native.replace({self.native.named["PNG"]: png, 8: bitmap.getvalue()[14:]})
        return {"copied": True, "changeCount": self.sequence}

    def begin_native(self, formats, target_id=None, send_enter=False, stack_count=0) -> dict:
        if self.transaction is not None:
            raise AppError("请先确认或取消上一项粘贴。", "busy")
        if self.desktop is None:
            raise AppError("此会话没有交互桌面。", "unavailable")
        from gaocaozuo.platform_win import send_keys

        target = self.desktop.target(target_id) if target_id else self.desktop.capture_external()
        self.desktop.focus_target(target)
        self.desktop.require_foreground(target)
        focus, secure, editable = self.native.focus_details(target.hwnd)
        if not focus or secure or not editable:
            raise AppError("Windows 无法核验目标为非密码文本区。可复制后手动粘贴。", "blocked")
        source_sequence, original = self.native.snapshot()
        transaction = PasteTransaction(source_sequence, {}, bool(send_enter))
        self.desktop.require_foreground(target)
        if self.native.focus_details(target.hwnd) != (focus, False, True):
            raise AppError("输入目标已变化，未提交粘贴。", "changed")
        self.sequence = self.native.replace(formats, source_sequence, fallback=original)
        transaction.installed_temporary(self.sequence)
        self.transaction, self.original, self.temporary = transaction, original, formats
        self.target, self.focus = target, focus
        self.stack_capture_count = stack_count
        try:
            if not self._target_matches() or self.native.sequence() != self.sequence or not send_keys((0x11, ord("V")), expected_window=target.hwnd):
                raise AppError("输入目标或系统剪贴板已变化，未提交粘贴。", "changed")
        except AppError:
            transaction.failed_before_submission()
            self.cancel()
            raise
        transaction.submitted(self.sequence, True)
        return {"id": transaction.id, "phase": transaction.phase, "eventWasSubmitted": True, "automaticEnter": False}

    def _target_matches(self) -> bool:
        self.desktop.require_foreground(self.target)
        return self.native.focus_details(self.target.hwnd) == (self.focus, False, True)

    def _finish(self, formats):
        transaction = self.transaction
        if transaction is None:
            raise AppError("没有等待核对的粘贴。", "invalid")
        if self.native.sequence() != transaction.temporary_change_count:
            self._release()
            raise AppError("系统剪贴板已更新，保留了新内容。", "changed")
        self.sequence = self.native.replace(formats, transaction.temporary_change_count, fallback=self.temporary)
        self._release()

    def _release(self):
        self.transaction = self.original = self.temporary = self.target = self.focus = None
        self.stack = []
        self.stack_capture_count = 0

    def confirm(self) -> dict:
        transaction = self.transaction
        if transaction is None or transaction.phase != "awaitingUser":
            raise AppError("没有已提交且等待核对的粘贴。", "invalid")
        restored = not self.stack
        formats = self.original if restored else self.native.part_formats(self.stack)
        stack_count = self.stack_capture_count
        self._finish(formats)
        if stack_count:
            del self.multiple[:stack_count]
        transaction.begin_completion()
        transaction.completed()
        return {"id": transaction.id, "phase": transaction.phase, "restored": restored, "enterSubmitted": transaction.enter_was_submitted}

    def cancel(self) -> dict:
        self._finish(self.original)
        return {"restored": True, "changeCount": self.sequence}

    def enter(self, role=None, editable=False) -> dict:
        transaction = self.transaction
        if transaction is None or transaction.phase != "awaitingUser" or not transaction.send_enter_requested or transaction.enter_was_submitted:
            raise AppError("没有等待手动提交的回车。", "invalid")
        from gaocaozuo.platform_win import send_keys

        self.desktop.focus_target(self.target)
        if not self._target_matches() or not send_keys((0x0D,), expected_window=self.target.hwnd):
            raise AppError("目标文本区已变化，未提交回车。", "changed")
        transaction.record_enter("Edit", True)
        return {"enterSubmitted": True, "automatic": False}
