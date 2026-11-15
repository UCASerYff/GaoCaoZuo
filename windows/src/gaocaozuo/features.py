"""短语、组合操作、交接票据和输入规则同步。"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError
from gaocaozuo.images import table_xlsx
from gaocaozuo.version import SCHEMA_VERSION


def expand_snippet(text: str, now: datetime, clipboard_text: str | None, identifier: str, secure_input: bool) -> str:
    content = text
    content = content.replace("{date}", now.strftime("%Y-%m-%d"))
    content = content.replace("{time}", now.strftime("%H:%M:%S"))
    content = content.replace("{datetime}", now.strftime("%Y-%m-%d %H:%M:%S"))
    content = content.replace("{year}", now.strftime("%Y"))
    content = content.replace("{month}", now.strftime("%m"))
    content = content.replace("{day}", now.strftime("%d"))
    content = content.replace("{uuid}", identifier)
    if "{clipboard}" in content:
        content = content.replace("{clipboard}", "" if secure_input or clipboard_text is None else clipboard_text)
    return content


class SnippetLibrary:
    def __init__(self, path: Path):
        self.path = path
        self.raw: dict | None = None
        self.status = "missing"
        self.notice = ""
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            self.status = "missing"
            self.raw = None
            return
        try:
            parsed = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            self.status = "corrupt"
            self.notice = "短语库无法读取，已停止写入。"
            self.raw = None
            return
        if not isinstance(parsed, dict) or parsed.get("schema") != SCHEMA_VERSION:
            self.status = "newer"
            self.notice = "短语库版本不受支持，已停止写入。"
            self.raw = None
            return
        self.raw = parsed
        self.status = "ready"

    def _ensure(self) -> dict:
        if self.status == "corrupt" or self.status == "newer":
            raise AppError(self.notice, self.status)
        if self.raw is None:
            self.raw = {"schema": SCHEMA_VERSION, "groups": [{"id": "default", "name": "默认"}], "snippets": []}
            self.status = "ready"
        return self.raw

    def save_snippet(self, snippet: dict) -> dict:
        raw = self._ensure()
        snippets = raw.setdefault("snippets", [])
        shortcut = (snippet.get("shortcut") or "").strip()
        for existing in snippets:
            if shortcut and existing.get("shortcut") == shortcut and existing.get("id") != snippet.get("id"):
                raise AppError("短语快捷码必须唯一。", "conflict")
        if not snippet.get("name") or "text" not in snippet:
            raise AppError("短语需要名称和内容。", "invalid")
        record = {
            "id": snippet.get("id") or str(uuid.uuid4()),
            "name": snippet["name"],
            "text": snippet["text"],
            "group": snippet.get("group") or "default",
            "tags": list(snippet.get("tags") or []),
            "shortcut": shortcut,
            "mode": snippet.get("mode") or "copyOnly",
        }
        replaced = False
        for index, existing in enumerate(snippets):
            if existing.get("id") == record["id"]:
                preserved = {key: value for key, value in existing.items() if key not in record}
                snippets[index] = {**preserved, **record}
                record = snippets[index]
                replaced = True
                break
        if not replaced:
            snippets.append(record)
        self._write(raw)
        return record

    def resolve(self, snippet_id: str, now: datetime, clipboard_text: str | None, secure_input: bool) -> str:
        raw = self._ensure()
        for snippet in raw.get("snippets") or []:
            if snippet.get("id") == snippet_id:
                return expand_snippet(snippet.get("text") or "", now, clipboard_text, str(uuid.uuid4()), secure_input)
        raise AppError("找不到短语。", "missing")

    def export_csv(self) -> str:
        raw = self._ensure()
        lines = ["名称,快捷码,内容"]
        for snippet in raw.get("snippets") or []:
            cells = [snippet.get("name", ""), snippet.get("shortcut", ""), snippet.get("text", "")]
            lines.append(",".join('"' + cell.replace('"', '""') + '"' for cell in cells))
        return "\ufeff" + "\r\n".join(lines) + "\r\n"

    def export_xlsx(self) -> bytes:
        raw = self._ensure()
        rows = [["名称", "快捷码", "内容"]]
        for snippet in raw.get("snippets") or []:
            rows.append([snippet.get("name", ""), snippet.get("shortcut", ""), snippet.get("text", "")])
        return table_xlsx(rows)

    def _write(self, raw: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        atomic_replace(self.path, (json.dumps(raw, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        self.raw = raw
        self.status = "ready"


def run_workflow(steps: list[dict], invoke) -> dict:
    completed = []
    for step in steps:
        try:
            result = invoke(step)
        except AppError as exc:
            return {"stopped": True, "error": exc.message, "code": exc.code, "completed": completed}
        completed.append({"actionID": step.get("actionID"), "result": result})
    return {"stopped": False, "completed": completed}


class Handoff:
    def __init__(self, ttl_seconds: float = 30):
        self.ttl = ttl_seconds
        self.tickets: dict[str, dict] = {}
        self.reviews: dict[str, dict] = {}

    def issue(self, action: str, paths: list[str], now: float) -> str:
        token = uuid.uuid4().hex
        self.tickets[token] = {"action": action, "paths": list(paths), "exp": now + self.ttl, "used": False}
        return token

    def consume(self, token: str, now: float) -> dict:
        ticket = self.tickets.get(token)
        if ticket is None or ticket["used"] or now > ticket["exp"]:
            raise AppError("交接票据无效、已使用或已过期。", "ticket")
        ticket["used"] = True
        return {"action": ticket["action"], "paths": list(ticket["paths"])}

    def submit_payload_url(self, url: str) -> dict:
        parsed = urlparse(url)
        query = parse_qs(parsed.query)
        action = (query.get("action") or [""])[0]
        paths = query.get("path") or []
        review_id = str(uuid.uuid4())
        self.reviews[review_id] = {"url": url, "action": action, "paths": paths, "approved": False, "executed": False}
        return {"reviewID": review_id, "executed": False, "action": action, "paths": paths}

    def approve(self, review_id: str) -> dict:
        review = self.reviews.get(review_id)
        if review is None:
            raise AppError("没有这项待复核的外部请求。", "missing")
        if review["executed"]:
            raise AppError("这项外部请求已经执行过。", "invalid")
        review["approved"] = True
        review["executed"] = True
        return {"reviewID": review_id, "executed": True, "action": review["action"], "paths": list(review["paths"])}

    def redact(self, text: str) -> str:
        redacted = text
        for token in self.tickets:
            redacted = redacted.replace(token, "[ticket]")
        for review in self.reviews.values():
            redacted = redacted.replace(review["url"], "[payload]")
            for path in review["paths"]:
                redacted = redacted.replace(path, "[path]")
        return redacted


def semantic(rule: dict) -> tuple:
    return (
        rule.get("actionID"),
        rule.get("script") or "",
        rule.get("shortcut") or "",
        rule.get("kind") or "action",
        tuple(rule.get("include") or []),
        tuple(rule.get("exclude") or []),
    )


def scopes_overlap(left: dict, right: dict) -> bool:
    inc_a = set(left.get("include") or [])
    inc_b = set(right.get("include") or [])
    exc_a = set(left.get("exclude") or [])
    exc_b = set(right.get("exclude") or [])
    if not inc_a and not inc_b:
        return True
    if not inc_a:
        return bool(inc_b - exc_a)
    if not inc_b:
        return bool(inc_a - exc_b)
    return bool((inc_a - exc_b) & (inc_b - exc_a))


def shortcut_conflicts(rules: list[dict]) -> list[tuple[str, str]]:
    active = [rule for rule in rules if rule.get("enabled") and not rule.get("paused") and rule.get("shortcut")]
    found = []
    for index, left in enumerate(active):
        for right in active[index + 1 :]:
            if left.get("shortcut") == right.get("shortcut") and scopes_overlap(left, right):
                found.append((left.get("id", ""), right.get("id", "")))
    return found


def needs_review(old: dict | None, new: dict) -> bool:
    if old is None:
        return True
    if not old.get("enabled") and new.get("enabled"):
        return True
    return semantic(old) != semantic(new)


def import_rules(local: list[dict], remote: list[dict], tombstones: list[str]) -> dict:
    local_by_id = {rule.get("id"): rule for rule in local}
    accepted = []
    pending = []
    remote_ids = set()
    for rule in remote:
        if rule.get("id") in tombstones:
            continue
        remote_ids.add(rule.get("id"))
        old = local_by_id.get(rule.get("id"))
        if needs_review(old, rule):
            pending.append({**rule, "enabled": False, "needsReview": True})
        else:
            accepted.append(dict(old or rule))
    for rule in local:
        if rule.get("id") not in remote_ids and rule.get("id") not in tombstones:
            accepted.append(dict(rule))
    return {"accepted": accepted, "pending": pending}


def merge_configurations(base: list[dict], local: list[dict], remote: list[dict]) -> dict:
    if local != base and remote != base and local != remote:
        return {"value": local, "conflicts": ["rules"]}
    if remote != base and local == base:
        return {"value": remote, "conflicts": []}
    return {"value": local, "conflicts": []}


def validate_package(document: dict, now: str) -> dict:
    required = [
        "schemaVersion",
        "kind",
        "requestID",
        "sourceBundleID",
        "targetBundleID",
        "action",
        "createdAt",
        "expiresAt",
        "nonce",
    ]
    if document.get("schemaVersion") != 1:
        raise AppError("交接包版本不受支持。", "newer")
    if any(key not in document for key in required):
        raise AppError("交接包缺少字段。", "invalid")
    if str(document.get("expiresAt")) < now:
        raise AppError("交接包已过期。", "expired")
    for item in document.get("items") or []:
        path = str(item.get("path") or "")
        parts = path.replace("\\", "/").split("/")
        if path.startswith("/") or path.startswith("\\") or ".." in parts or (len(path) > 1 and path[1] == ":"):
            raise AppError(f"交接包路径越界：{path}", "unsafe")
    parameters = document.get("parameters") or {}
    if parameters.get("useDuplicateFileEngine") and not parameters.get("duplicateFileEngine"):
        raise AppError("提供方未声明重复文件引擎，已禁用该选项。", "unavailable")
    return {"accepted": True, "completed": False, "openedIsCompleted": False}


def cloud_payload(rules: list[dict]) -> dict:
    exported = []
    for rule in rules:
        exported.append(
            {
                "id": rule.get("id"),
                "name": rule.get("name"),
                "actionID": rule.get("actionID"),
                "shortcut": rule.get("shortcut"),
                "enabled": bool(rule.get("enabled")),
                "include": list(rule.get("include") or []),
                "exclude": list(rule.get("exclude") or []),
                "script": rule.get("script") or "",
                "kind": rule.get("kind") or "action",
            }
        )
    return {"schema": SCHEMA_VERSION, "rules": exported, "clipboard": None, "snippets": None, "passwords": None}


def append_revision(folder: Path, device_id: str, parents: list[str], rules: list[dict]) -> dict:
    folder.mkdir(parents=True, exist_ok=True)
    document = {
        "schema": SCHEMA_VERSION,
        "revisionID": str(uuid.uuid4()),
        "deviceID": device_id,
        "parents": list(parents),
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "configuration": cloud_payload(rules),
    }
    path = folder / f"{document['revisionID']}.json"
    atomic_replace(path, (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return document
