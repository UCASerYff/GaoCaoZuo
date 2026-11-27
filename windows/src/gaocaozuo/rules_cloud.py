"""Append-only Windows input rule sync through the iCloud Drive filesystem."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
import time
from pathlib import Path

from gaocaozuo.errors import AppError

IDENTIFIER = re.compile(r"[a-f0-9]{64}\Z")
RULE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
ROOT_NAME = "GaoCaoZuo-Windows-Rules"
MAX_REVISIONS = 2048
MAX_REVISION_BYTES = 262144
FIELDS = {"id", "name", "actionID", "enabled", "kind", "shortcut", "include", "exclude", "application", "appBundleID",
          "trigger", "mouseButton", "mouseModifiers", "direction", "modifiers"}
SCOPE = re.compile(r"[^\\/:\x00-\x1f]{1,128}\Z")


def _canonical(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _hash(raw):
    return hashlib.sha256(raw).hexdigest()


def _portable(rule, *, remote=False):
    if not isinstance(rule, dict) or not RULE_ID.fullmatch(str(rule.get("id", ""))) or not isinstance(rule.get("id"), str):
        raise AppError("输入规则编号无效。", "invalid")
    if remote and not set(rule) <= FIELDS:
        raise AppError("云端规则含不允许同步的字段。", "invalid")
    if rule.get("script") or rule.get("kind", "action") != "action":
        if remote:
            raise AppError("云端规则不能同步脚本。", "invalid")
        return None
    exported = {key: value for key, value in rule.items() if key in FIELDS}
    if not isinstance(exported.get("actionID"), str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", exported["actionID"]):
        raise AppError("输入规则动作编号无效。", "invalid")
    exported["enabled"] = bool(rule.get("cloudWantsEnabled") if rule.get("needsReview") and not remote else rule.get("enabled"))
    if remote and type(rule.get("enabled")) is not bool:
        raise AppError("云端规则启用状态无效。", "invalid")
    for field in ("application", "appBundleID", "include", "exclude"):
        if field not in exported:
            continue
        value = exported[field]
        values = value if field in {"include", "exclude"} else [value]
        if values == [""] and field not in {"include", "exclude"}:
            continue
        if not isinstance(values, list) or len(values) > 50 or any(not isinstance(item, str) or not SCOPE.fullmatch(item) for item in values):
            if not remote:
                return None
            raise AppError("云端规则包含无效的程序范围。", "invalid")
    for field, value in exported.items():
        if field in {"id", "enabled", "application", "appBundleID", "include", "exclude"}:
            continue
        if field == "mouseButton" and type(value) is int and value in (1, 2, 3, 4, 5):
            continue
        if not isinstance(value, str) or len(value) > 256 or "\0" in value:
            raise AppError("规则字段超出同步范围。", "invalid")
    return exported


def _rules(rows, *, remote=False):
    if not isinstance(rows, list) or len(rows) > 500:
        raise AppError("同步规则数量超过上限。", "budget")
    indexed = {}
    for rule in rows:
        portable = _portable(rule, remote=remote)
        if portable is None:
            continue
        name = portable["id"]
        if name in indexed:
            raise AppError("同步规则中有重复编号。", "invalid")
        indexed[name] = portable
    return indexed


def _apple_provider(path):
    if os.name != "nt":
        return False
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.native_win import bind

    class Provider(c.Structure):
        _fields_ = [("status", w.DWORD), ("name", w.WCHAR * 256), ("version", w.WCHAR * 256)]

    info = Provider()
    try:
        query = bind("CldApi", "CfGetSyncRootInfoByPath", c.c_long, w.LPCWSTR, c.c_int, w.LPVOID,
                     w.DWORD, c.POINTER(w.DWORD))
        status = query(str(path), 2, c.byref(info), c.sizeof(info), None)
    except (OSError, AttributeError):
        return False
    return status == 0 and "icloud" in info.name.casefold()


def _item(path, directory):
    info = path.lstat()
    attributes = getattr(info, "st_file_attributes", 0)
    tag = getattr(info, "st_reparse_tag", 0)
    if attributes & (0x1000 | 0x40000 | 0x400000):
        raise AppError("iCloud 文件还未下载，请在资源管理器中保留到本机。", "cloudPending")
    allowed = tag & 0xFFFF0FFF == 0x9000001A
    if path.is_symlink() or (attributes & 0x400 and not allowed) or (
            directory and not stat.S_ISDIR(info.st_mode)) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise AppError("同步路径含链接或非预期文件，已暂停同步。", "unsafe")
    return info


def _node(info):
    return info.st_dev, info.st_ino


class Workspace:
    def __init__(self, selected: Path, provider):
        if not selected.is_absolute() or (os.name == "nt" and selected.drive.startswith("\\")):
            raise AppError("请选择 Windows iCloud Drive 下的本机目录。", "invalid")
        for part in (*reversed(selected.parents), selected):
            _item(part, True)
        if not provider(selected):
            raise AppError("系统未识别该目录为 iCloud Drive，请重新选择。", "unavailable")
        self.selected = selected
        self.selected_id = _node(_item(selected, True))
        self.root = selected / ROOT_NAME
        self.root.mkdir(exist_ok=True)
        self.root_id = _node(_item(self.root, True))

    def check(self):
        if _node(_item(self.selected, True)) != self.selected_id or _node(_item(self.root, True)) != self.root_id:
            raise AppError("iCloud 同步目录身份已变化，请重新配置。", "changed")

    def read(self):
        self.check()
        revisions = {}
        for path in self.root.iterdir():
            name = path.stem
            if path.suffix != ".json" or not IDENTIFIER.fullmatch(name):
                continue
            if len(revisions) >= MAX_REVISIONS:
                raise AppError("iCloud 修订数量已达上限。", "budget")
            first = _item(path, False)
            if first.st_size > MAX_REVISION_BYTES:
                raise AppError("iCloud 修订文件超过大小上限。", "budget")
            with path.open("rb") as source:
                raw = source.read(MAX_REVISION_BYTES + 1)
                if _node(os.fstat(source.fileno())) != _node(first) or _node(_item(path, False)) != _node(first):
                    raise AppError("iCloud 修订文件在读取时发生变化。", "changed")
            if _hash(raw) != name:
                raise AppError("iCloud 修订文件校验失败，已停止同步。", "corrupt")
            try:
                data = json.loads(raw)
            except (ValueError, UnicodeError) as exc:
                raise AppError("iCloud 修订文件损坏。", "corrupt") from exc
            if not isinstance(data, dict) or data.get("schema") != 1 or set(data) != {"schema", "parents", "rules"}:
                raise AppError("iCloud 修订版本不受支持。", "newer")
            parents = data["parents"]
            if not isinstance(parents, list) or len(parents) > 64 or any(not isinstance(p, str) or not IDENTIFIER.fullmatch(p) for p in parents) or len(set(parents)) != len(parents):
                raise AppError("iCloud 修订祖先格式无效。", "invalid")
            revisions[name] = parents, _rules(data["rules"], remote=True)
        self.check()
        return revisions

    def publish(self, parents, rules):
        data = _canonical({"schema": 1, "parents": sorted(parents), "rules": [rules[key] for key in sorted(rules)]})
        if len(data) > MAX_REVISION_BYTES:
            raise AppError("同步规则修订超过大小上限。", "budget")
        name = _hash(data)
        target = self.root / (name + ".json")
        self.check()
        if target.exists():
            if _item(target, False).st_size == len(data) and target.read_bytes() == data:
                return name
            raise AppError("iCloud 修订冲突，现有文件已保留。", "conflict")
        fd, staged = tempfile.mkstemp(prefix=".gao-sync-", suffix=".tmp", dir=self.root)
        try:
            with os.fdopen(fd, "wb") as file:
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            self.check()
            try:
                if os.name == "nt":
                    os.rename(staged, target)
                else:
                    os.link(staged, target)
            except FileExistsError:
                if _item(target, False).st_size != len(data) or target.read_bytes() != data:
                    raise AppError("iCloud 修订冲突，现有文件已保留。", "conflict")
        finally:
            Path(staged).unlink(missing_ok=True)
        return name


def _frontier(revisions, applied):
    referenced = {parent for parents, _rules in revisions.values() for parent in parents}
    if not (referenced | set(applied)) <= revisions.keys():
        raise AppError("iCloud 修订尚未全部到达。已保留本机版本。", "cloudPending")
    return sorted(revisions.keys() - referenced)


def _base(revisions, anchors):
    if len(anchors) <= 1:
        return revisions[anchors[0]][1] if anchors else {}

    def ancestors(start):
        pending, seen = [start], set()
        while pending:
            current = pending.pop()
            if current not in seen:
                seen.add(current)
                pending.extend(revisions[current][0])
        return seen

    common = set.intersection(*(ancestors(head) for head in anchors))
    prior = {parent for head in common for parent in revisions[head][0]}
    newest = common - prior
    if len(newest) > 1:
        return None
    return revisions[newest.pop()][1] if newest else {}


def _merge(base, local, choices):
    merged = {}
    conflicts = []
    ids = set(local).union(base, *(set(choice) for choice in choices))
    for key in sorted(ids):
        old = base.get(key)
        values = []
        for value in [local.get(key), *(choice.get(key) for choice in choices)]:
            if value != old and value not in values:
                values.append(value)
        chosen = values[0] if len(values) == 1 else local.get(key)
        if len(values) > 1:
            conflicts.append(key)
        if chosen is not None:
            merged[key] = chosen
    return merged, conflicts


def _local_review(rows, prior, final):
    from gaocaozuo.features import needs_review

    result = []
    originals = {row["id"]: row for row in rows}
    for key in dict.fromkeys([*(row["id"] for row in rows), *final]):
        value = final.get(key)
        original = originals.get(key)
        if value is None:
            if original is not None and key not in prior:
                result.append(original)
            continue
        if original is not None and key not in prior:
            raise AppError("云端规则与本机专用规则编号相同，已保留两边。", "conflict")
        current = {**(original or {}), **value}
        for field in FIELDS - value.keys():
            current.pop(field, None)
        if (original or {}).get("needsReview") or needs_review(prior.get(key), value):
            current.update(enabled=False, needsReview=True, cloudWantsEnabled=value["enabled"])
        result.append(current)
    return result


class RuleCloud:
    def __init__(self, read_document, write_document, provider=_apple_provider):
        self.read_document = read_document
        self.write_document = write_document
        self.provider = provider
        self.next_poll = 0.0
        self.result = {"status": "off", "conflicts": [], "choices": []}

    def configure(self, folder, confirmed):
        if confirmed is not True:
            raise AppError("请确认此 iCloud Drive 同步范围。", "confirmation")
        doc = self.read_document()
        if folder:
            workspace = Workspace(Path(folder), self.provider)
            old = doc.get("windowsCloud") or {}
            same = str(workspace.selected) == old.get("folder") and list(workspace.root_id) == old.get("identity")
            doc["windowsCloud"] = old if same else {"folder": str(workspace.selected), "identity": list(workspace.root_id), "applied": []}
        else:
            doc.pop("windowsCloud", None)
        self.write_document(doc)
        return self.poll(force=True)

    def poll(self, force=False, choice=None, token=None):
        now = time.monotonic()
        if not force and now < self.next_poll:
            return self.result
        self.next_poll = now + 15
        try:
            return self._sync(choice, token)
        except (AppError, OSError) as exc:
            kind = exc.code if isinstance(exc, AppError) else "cloudPending"
            message = exc.message if isinstance(exc, AppError) else "iCloud Drive 暂不可读写，已保留本机规则。"
            self.result = {"status": kind, "message": message, "conflicts": [], "choices": []}
            return self.result

    def _sync(self, choice, token):
        doc = self.read_document()
        settings = doc.get("windowsCloud")
        if settings is None:
            self.result = {"status": "off", "conflicts": [], "choices": []}
            return self.result
        if (not isinstance(settings, dict) or not isinstance(settings.get("folder"), str)
                or not isinstance(settings.get("applied"), list) or len(settings["applied"]) > 64
                or any(not isinstance(revision, str) or not IDENTIFIER.fullmatch(revision) for revision in settings["applied"])):
            raise AppError("本机 iCloud 同步设置损坏。", "corrupt")
        workspace = Workspace(Path(settings["folder"]), self.provider)
        if list(workspace.root_id) != settings.get("identity"):
            raise AppError("iCloud 同步目录身份已变化，请重新配置。", "changed")
        revisions = workspace.read()
        heads = _frontier(revisions, settings["applied"])
        if revisions and not heads or len(heads) > 64:
            raise AppError("iCloud 修订分支无效或超过上限。", "corrupt")
        local = _rules(doc["rules"])
        base = _base(revisions, sorted(set(heads + settings["applied"])))
        if not settings["applied"]:
            base = {}
        choices = {key: revisions[key][1] for key in heads}
        candidate, conflicts = (_merge(base, local, choices.values()) if base is not None else (local.copy(), ["configuration"]))
        review_id = _hash(_canonical({"heads": heads, "local": local, "conflicts": conflicts}))
        if conflicts:
            if choice is None or token != review_id or (choice != "local" and choice not in choices):
                self.result = {"status": "conflict", "folder": str(workspace.selected), "conflicts": conflicts, "token": review_id,
                               "choices": [{"id": key, "count": len(value)} for key, value in choices.items()]}
                return self.result
            chosen = local if choice == "local" else choices[choice]
            if conflicts == ["configuration"]:
                candidate = chosen
            else:
                for key in conflicts:
                    if key in chosen:
                        candidate[key] = chosen[key]
                    else:
                        candidate.pop(key, None)
        safe = _local_review(doc["rules"], local, candidate)
        if len(heads) != 1 or candidate != choices.get(heads[0]):
            heads = [workspace.publish(heads, candidate)]
        if doc["rules"] != safe or settings["applied"] != heads:
            self.write_document({**doc, "rules": safe, "windowsCloud": {**settings, "applied": heads}})
        self.result = {"status": "localSynced", "folder": str(workspace.selected), "conflicts": [], "choices": [],
                       "pending": sum(bool(rule.get("needsReview")) for rule in safe), "heads": heads}
        return self.result

    def approve(self, rule_id, accept, confirmed):
        if confirmed is not True:
            raise AppError("请确认这条规则在本机的动作。", "confirmation")
        doc = self.read_document()
        rules = []
        found = False
        for row in doc["rules"]:
            if row.get("id") == rule_id and row.get("needsReview"):
                current = dict(row)
                enabled = current.pop("cloudWantsEnabled", False)
                current.pop("needsReview", None)
                current["enabled"] = bool(accept and enabled)
                row = current
                found = True
            rules.append(row)
        if not found:
            raise AppError("该规则已变更或无需复核。", "changed")
        self.write_document({**doc, "rules": rules})
        return {"rules": rules}
