"""Plan Windows rules from hypothetical input without access to any effect backend."""

from __future__ import annotations

import re
from pathlib import PureWindowsPath

from gaocaozuo.catalog import find_action
from gaocaozuo.errors import AppError
from gaocaozuo.files import validate_name
from gaocaozuo.rules_win import Binding, trigger_key


_TRIGGER_FIELDS = ("trigger", "shortcut", "mouseButton", "mouseModifiers", "direction", "modifiers")
_IMAGE_TYPES = {"png", "bmp", "jpeg", "heic", "tiff", "webp", "icns", "convert"}
_ARCHIVE_FORMATS = {"archive.create": ".zip", "archive.custom": ".zip", "archive.7z": ".7z"}
_EXTRACTIONS = {"archive.extract", "archive.extract.custom"}
_CLIPBOARD_OUTPUTS = {"path.copy", "name.copy", "hash.sha256", "clipboard.copyplain"}
_OCR_ACTIONS = {"ocr.files", "file.ocr", "screenshot.ocr.capture", "screenshot.ocr.clipboard"}
_CONFIRMATION = _OCR_ACTIONS | {"window.close", "screenshot.capture", "screenshot.pins.restore"}
_FILE_ACTIONS = {"file.ocr"} | _EXTRACTIONS | set(_ARCHIVE_FORMATS)
_PATH_REQUIRED = {"archive.list", "terminal.open", "finder.reveal", "folder.favorite.add"}
_MISSING_DIRECTORY = {"files.copy", "files.move"}
_SCREEN_ONLY = {"screenshot.long", "screenshot.annotate"}
_FILE_UNCERTAINTY = "未读取真实文件，名称冲突、权限和文件内容须在执行时核实。"
_WINDOW_UNCERTAINTY = "未检查真实窗口和显示器，执行时须重新核验目标。"
_ACTION_UNCERTAINTY = "未调用 Windows 或业务接口，实际结果须在执行时核实。"
_WINDOW_FOCUS = {"title": "聚焦窗口"}
# These placeholder choices exist in the legacy workflow editor, but App.perform has no handlers.
_UNIMPLEMENTED_WORKFLOW_TITLES = {"delay": "等待", "open.path": "打开路径", "open.url": "打开网址"}


def _paths(value, limit):
    if not isinstance(value, list) or len(value) > limit:
        raise AppError("模拟路径列表无效。", "invalid")
    result = []
    for raw in value:
        if not isinstance(raw, str) or not raw or len(raw) > 1024 or any(ord(char) < 32 for char in raw):
            raise AppError("模拟路径无效。", "invalid")
        path = PureWindowsPath(raw)
        if not path.is_absolute() or not path.name or raw.replace("/", "\\").startswith(("\\\\?\\", "\\\\.\\")):
            raise AppError("请输入模拟的绝对路径。", "invalid")
        for part in path.parts[1:]:
            if PureWindowsPath(part).is_reserved():
                raise AppError("模拟路径无效。", "invalid")
            validate_name(part)
        result.append(path)
    return result


def _condition(label, status, detail):
    return {"label": label, "status": status, "detail": detail}


def _effect(kind, operation, *, path=None, source=None):
    value = {"kind": kind, "operation": operation}
    if path is not None:
        value["path"] = str(path)
    if source is not None:
        value["source"] = str(source)
    return value


def _supported_rule(rule):
    return not rule.get("script") and rule.get("kind", "action") == "action"


def _enabled(rule):
    return bool(rule.get("enabled")) and not rule.get("paused") and not rule.get("needsReview")


def _rule_conditions(rule, sample, settings, rules):
    binding = Binding.from_rule(rule) if _supported_rule(rule) else None
    enabled = _enabled(rule)
    active = bool(settings.get("windowsAutomationEnabled")) and not settings.get("inputPaused")
    index = next((index for index, item in enumerate(rules) if isinstance(item, dict) and item.get("id") == rule.get("id")), len(rules))
    loaded = index < 512
    conditions = [
        _condition("规则状态", "match" if enabled else "blocked", "规则已启用。" if enabled else
                   "规则仍待复核。" if rule.get("needsReview") else "规则已停用或暂停。"),
        _condition("输入监听", "match" if active else "blocked", "输入监听已启用。" if active else "输入监听已关闭或暂停。"),
    ]
    if not binding:
        conditions.append(_condition("规则配置", "blocked", "Windows 仅支持应用动作规则。" if not _supported_rule(rule)
                                     else "规则的触发方式或动作无效。"))
        return False, "blocked", conditions

    if not loaded:
        conditions.append(_condition("加载范围", "blocked", "规则超出 Windows 的加载范围。"))

    application = sample.get("application", "")
    if not isinstance(application, str) or len(application) > 260 or any(ord(char) < 32 for char in application):
        raise AppError("模拟应用名称无效。", "invalid")
    application = PureWindowsPath(application.strip()).name.casefold()
    trigger = sample.get("trigger", binding.key[0])
    template = {field: rule[field] for field in _TRIGGER_FIELDS if field in rule} if trigger == binding.key[0] else {}
    observed = trigger_key({**template, **{field: sample[field] for field in _TRIGGER_FIELDS if field in sample}, "trigger": trigger})
    if observed is None:
        conditions.append(_condition("模拟触发", "blocked", "模拟触发输入无效。"))
        return False, "blocked", conditions
    key_match, scope_match = observed == binding.key, binding.matches(application)
    conditions.extend((
        _condition("模拟触发", "match" if key_match else "mismatch", "触发输入匹配。" if key_match else "触发输入不匹配。"),
        _condition("模拟应用", "match" if scope_match else "mismatch", "应用范围匹配。" if scope_match else "应用不在规则范围内。"),
    ))
    if not key_match or not scope_match:
        return False, "notMatched", conditions
    conflicting = any(other.key == binding.key and other.matches(application)
                      for candidate in rules[:512]
                      if isinstance(candidate, dict) and candidate.get("id") != rule.get("id")
                      and _enabled(candidate) and _supported_rule(candidate)
                      and (other := Binding.from_rule(candidate)) is not None)
    conditions.append(_condition("触发冲突", "blocked" if conflicting else "match",
                                 "同一模拟应用中有多条启用规则使用此触发方式。" if conflicting else "没有匹配的规则冲突。"))
    conditions.append(_condition("真实系统", "unknown", "未检查系统注册、前台窗口和权限。"))
    return True, "planned" if enabled and active and loaded and not conflicting else "blocked", conditions


def _reserve(used, folder, stem, suffix):
    for number in range(1, 10000):
        name = stem + (f" {number}" if number > 1 else "") + suffix
        validate_name(name)
        candidate = folder / name
        if candidate not in used:
            used.add(candidate)
            return candidate
    raise AppError("重名编号超过上限，已停止。", "invalid")


def _archive_base(path):
    if re.fullmatch(r"\.[0-9]{3}", path.suffix):
        path = path.with_suffix("")
    if path.suffix.casefold() not in {".zip", ".7z"}:
        raise AppError("可预览和解压 ZIP、7Z 及它们的连续数字分卷。", "unsupported")
    return path


def _step_action(action_id, item, kind, paths, used, extracted):
    # The live input runtime passes only an input-rule ID and possibly a window identity.
    # The live combination runner forwards its selected paths, target and confirmation.
    if item.get("files") or action_id in _FILE_ACTIONS:
        if kind == "rule":
            return [], "输入规则运行时不会收到文件选择。", ""
        if not paths:
            return [], "请先选择文件。", ""
    if kind == "rule" and action_id in _CONFIRMATION:
        return [], "此动作需要单独确认。", ""
    if action_id in _SCREEN_ONLY:
        return [], "此动作请在截图工具中操作。", ""
    if action_id in _MISSING_DIRECTORY or action_id.startswith(("new.", "file.new.")):
        return [], "缺少目标目录。", ""
    if action_id in _PATH_REQUIRED:
        return [], "缺少单项路径参数。", ""
    if action_id in _ARCHIVE_FORMATS:
        if len({path.name.casefold() for path in paths}) != len(paths):
            return [], "模拟来源包含同名项目。", ""
        first = paths[0]
        destination = _reserve(used, first.parent, first.stem, _ARCHIVE_FORMATS[action_id])
        return [_effect("file", "创建压缩包", path=destination)], "", _FILE_UNCERTAINTY
    if action_id in _EXTRACTIONS:
        effects, seen = [], set()
        for path in paths:
            try:
                archive = _archive_base(path)
                key = (archive, archive != path)
                if key in seen:
                    continue
                seen.add(key)
                if key in extracted:
                    effects.append(_effect("action", "沿用前一步的解压结果", path=extracted[key], source=path))
                    continue
                extracted[key] = _reserve(used, path.parent, archive.stem, "")
            except AppError as exc:
                return effects, exc.message, _FILE_UNCERTAINTY
            effects.append(_effect("file", "创建解压目录", path=extracted[key], source=path))
        return effects, "", "无法确认压缩包内容、密码、分卷和解压限制。"
    if action_id.startswith("images.") and (extension := action_id.partition(".")[2]) in _IMAGE_TYPES:
        suffix = ".jpg" if extension == "jpeg" else ".png" if extension == "convert" else "." + extension
        effects = [_effect("file", "生成图像", path=_reserve(used, path.parent, path.stem, suffix), source=path) for path in paths]
        return effects, "", _FILE_UNCERTAINTY
    if action_id in _CLIPBOARD_OUTPUTS:
        return [_effect("action", "写入剪贴板")], "", _ACTION_UNCERTAINTY
    if action_id == "files.rename":
        return [_effect("action", "预览重命名方案")], "", _FILE_UNCERTAINTY
    if action_id.startswith("window."):
        return [_effect("action", item["title"])], "", _WINDOW_UNCERTAINTY
    return [_effect("action", item["title"])], "", _ACTION_UNCERTAINTY


def _plan_steps(source, kind, paths, used, skipped):
    result, extracted = [], {}
    for index, step in enumerate(source, 1):
        action_id = step.get("actionID") if isinstance(step, dict) else None
        action_id = action_id if isinstance(action_id, str) and len(action_id) <= 160 else ""
        item = _WINDOW_FOCUS if action_id == "window.focus" else find_action("ocr.files" if action_id == "file.ocr" else action_id)
        title = item["title"] if item else _UNIMPLEMENTED_WORKFLOW_TITLES.get(action_id, action_id or "未指定动作")
        reason = skipped
        effects, uncertainty = [], ""
        if skipped:
            status = "skipped"
        else:
            if not item:
                reason = "嵌套组合请单独试跑。" if action_id.startswith("workflow.run.") else "Windows 没有此动作入口。"
            elif item.get("unavailableReason"):
                reason = item["unavailableReason"]
            else:
                try:
                    effects, reason, uncertainty = _step_action(action_id, item, kind, paths, used, extracted)
                except AppError as exc:
                    reason = exc.message
            status = "blocked" if reason else "planned"
            if reason:
                skipped = "前一步已阻断。"
        result.append({"index": index, "actionID": action_id, "title": title, "status": status, "effects": effects,
                       "reason": reason, "uncertainty": uncertainty})
    return result


def preview_rule(payload, *, rules, workflows, settings):
    """Accept only fixture strings and settings snapshots. Do not attach this planner to execution."""
    if not isinstance(payload, dict):
        raise AppError("试跑输入无效。", "invalid")
    kind, sample = payload.get("kind", "rule"), payload.get("sample", {})
    if kind not in ("rule", "workflow") or not isinstance(sample, dict):
        raise AppError("试跑输入无效。", "invalid")
    paths = _paths(sample.get("paths", []), 100)
    used = set(paths) | set(_paths(sample.get("existingPaths", []), 500))
    if kind == "rule":
        rule = payload.get("rule")
        if rule is None:
            selected_id = payload.get("ruleID") or ""
            rule = next((record for record in rules if isinstance(record, dict) and record.get("id") == selected_id), None)
        if not isinstance(rule, dict):
            raise AppError("找不到输入规则。", "missing")
        matched, outcome, conditions = _rule_conditions(rule, sample, settings or {}, rules)
        source = [rule]
    else:
        selected_id = payload.get("workflowID") or ""
        workflow = next((record for record in workflows if isinstance(record, dict) and record.get("id") == selected_id), None)
        if not workflow:
            raise AppError("找不到组合操作。", "missing")
        source = workflow.get("steps")
        if not isinstance(source, list) or not 1 <= len(source) <= 50:
            raise AppError("组合步骤无效。", "invalid")
        matched, outcome = True, "planned"
        conditions = [_condition("运行方式", "match", "组合操作由用户主动运行。"),
                      _condition("输入文件", "match" if paths else "unknown", "已提供模拟文件。" if paths else "未提供模拟文件。")]
    skipped = "触发条件不匹配。" if outcome == "notMatched" else next(
        (condition["detail"] for condition in conditions if condition["status"] == "blocked"), "")
    steps = _plan_steps(source, kind, paths, used, skipped if not matched else "")
    if matched and skipped:
        # Display the hypothetical action even when a matched binding is disabled locally.
        steps[0]["status"] = "blocked"
        steps[0]["reason"] = skipped
    if any(step["status"] == "blocked" for step in steps):
        outcome = "blocked"
    return {"kind": kind, "outcome": outcome, "matched": matched, "readOnly": True, "executed": False,
            "conditions": conditions, "steps": steps}
