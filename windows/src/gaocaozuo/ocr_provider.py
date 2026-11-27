"""GaoAction V1 file OCR provider with independent review and result export."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import stat
import tempfile
import uuid
from contextlib import contextmanager, nullcontext
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError
from gaocaozuo.ocr import ENGINE, FORMATS, MAX_PAGES, OcrSession, validate_languages
from gaocaozuo.ocr_return import RETURN_SOURCES, default_return_root, pinned_directory, pinned_path, rename_directory
from gaocaozuo.screenshot import MAX_INPUT_BYTES, write_new
from gaocaozuo.version import BUNDLE_ID, MARKETING_VERSION

if os.name == "nt":
    from gaocaozuo.ocr_provider_win import _open_windows_file, _windows_file_snapshot

MAX_MANIFEST_BYTES = 1_048_576
MAX_RETURN_TICKET_BYTES = 4096
MAX_PAYLOAD_BYTES = 2_147_483_648
MAX_PENDING = 128
MAX_STORE_BYTES = 8 * 1024 * 1024 * 1024
PNG_TYPES = {"public.png", "image/png"}
TYPES = PNG_TYPES | {
    "public.jpeg", "public.tiff", "com.compuserve.gif", "public.webp", "org.webmproject.webp",
    "image/jpeg", "image/tiff", "image/gif", "image/webp", "public.heic", "public.heif", "image/heic", "image/heif",
    "com.adobe.pdf", "application/pdf",
}
PDF_TYPES = {"com.adobe.pdf", "application/pdf"}
SHA = re.compile(r"[0-9a-f]{64}\Z")
BUNDLE = re.compile(r"[A-Za-z0-9.-]{1,255}\Z", re.ASCII)


def capabilities() -> dict:
    return {"schemaVersion": 1, "bundleID": BUNDLE_ID, "appVersion": MARKETING_VERSION, "actions": [{
        "action": "ocr.files", "supportsItems": True, "supportsReferences": False, "requiresUserConfirmation": True,
        "parametersSchema": {"type": "object", "additionalProperties": False, "properties": {
            "languages": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 12},
            "outputs": {"type": "array", "items": {"type": "string", "enum": list(FORMATS)}, "minItems": 1},
        }},
    }]}


def _request_uuid(value) -> str:
    try:
        identifier = str(uuid.UUID(value))
        if identifier != value.casefold():
            raise ValueError
        return identifier
    except (AttributeError, TypeError, ValueError) as exc:
        raise AppError("交接请求编号无效。", "invalid") from exc


def _date(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise AppError("交接请求时间无效。", "expired")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise AppError("交接请求时间无效。", "expired") from exc


def _fresh(manifest, now):
    created, expires = (_date(manifest.get(key)) for key in ("createdAt", "expiresAt"))
    if not created <= now < expires or not 0 < (expires - created).total_seconds() <= 120:
        raise AppError("交接请求已过期或时间无效，请让来源应用重新发送。", "expired")


def _stamp(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parts(value) -> tuple[str, ...]:
    if not isinstance(value, str) or len(value.encode("utf-8")) > 4096:
        raise AppError("交接附件路径无效。", "unsafe")
    parts = value.split("/")
    for part in parts:
        if (not part or part in {".", ".."} or part[-1] in " ." or any(ord(c) < 32 or c in '\\:<>"|?*' for c in part)
                or part.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
                or re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", part.split(".")[0], re.I)):
            raise AppError("交接附件路径无效。", "unsafe")
    return tuple(parts)


def _regular(path: Path, *, directory=False):
    info = path.lstat()
    mode = stat.S_ISDIR if directory else stat.S_ISREG
    if not mode(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400 or (not directory and info.st_nlink != 1):
        raise AppError("交接包目录或附件必须为普通、独立的文件对象。", "unsafe")
    return info


def _stat_snapshot(info):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AppError("交接文件在校验时发生变化。", "changed")
    return info.st_size, (info.st_dev, info.st_ino), info.st_mtime_ns, info.st_ctime_ns


def _file_snapshot(source, path):
    if os.name == "nt":
        return _windows_file_snapshot(source, path)
    return _stat_snapshot(os.fstat(source.fileno()))


def _check_current_path(path, expected):
    try:
        if os.name == "nt":
            with _open_windows_file(path) as source:
                current = _windows_file_snapshot(source, path)
        else:
            current = _stat_snapshot(_regular(path))
    except OSError as exc:
        raise AppError("交接文件位置在校验时发生变化。", "changed") from exc
    if current != expected:
        raise AppError("交接文件位置在校验时发生变化。", "changed")


def _read(path: Path, maximum: int, destination: Path | None = None, *, collect=True, sync=False) -> tuple[bytes | None, int, str]:
    if os.name == "nt":
        path_snapshot = None
        source = _open_windows_file(path)
    else:
        path_snapshot = _stat_snapshot(_regular(path))
        source = path.open("rb")
    with source as input_stream:
        first = _file_snapshot(input_stream, path)
        if path_snapshot is not None and first != path_snapshot:
            raise AppError("交接文件在校验时发生变化。", "changed")
        size = first[0]
        if size > maximum:
            raise AppError("交接文件超过处理限制。", "invalid")
        data = bytearray() if collect and destination is None else None
        digest = hashlib.sha256()
        count = 0
        output_stream = destination.open("xb") if destination else None
        try:
            while chunk := input_stream.read(1024 * 1024):
                count += len(chunk)
                if count > maximum:
                    raise AppError("交接文件超过处理限制。", "invalid")
                digest.update(chunk)
                if output_stream:
                    output_stream.write(chunk)
                elif data is not None:
                    data.extend(chunk)
            if output_stream and sync:
                output_stream.flush()
                os.fsync(output_stream.fileno())
        finally:
            if output_stream:
                output_stream.close()
        if size != count or first != _file_snapshot(input_stream, path):
            raise AppError("交接文件在读取时发生变化。", "changed")
        _check_current_path(path, first)
    return bytes(data) if data is not None else None, count, digest.hexdigest()


def _manifest(path, now):
    _regular(path, directory=True)
    try:
        blob, _size, digest = _read(path / "manifest.json", MAX_MANIFEST_BYTES)
        manifest = json.loads(blob.decode("utf-8"))
    except (OSError, ValueError, UnicodeError) as exc:
        raise AppError("无法读取交接清单。", "invalid") from exc
    if not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise AppError("交接清单版本无效。", "invalid")
    if manifest.get("action") != "ocr.files" or manifest.get("targetBundleID") != BUNDLE_ID or manifest.get("kind") != "request":
        raise AppError("此包的动作或目标不属于搞操作的 OCR 请求。", "wrongTarget")
    if any(manifest.get(key) is not None for key in ("inReplyTo", "status", "errorCode", "provenance")):
        raise AppError("OCR 请求包含结果字段。", "invalid")
    source = manifest.get("sourceBundleID")
    if not isinstance(source, str) or not BUNDLE.fullmatch(source) or "." not in source:
        raise AppError("来源应用标识无效。", "invalid")
    identifier = _request_uuid(manifest.get("requestID"))
    _fresh(manifest, now)
    try:
        nonce = base64.b64decode(manifest.get("nonce", ""), validate=True)
        if len(nonce) != 32:
            raise ValueError
    except (ValueError, TypeError, binascii.Error) as exc:
        raise AppError("交接随机数无效。", "invalid") from exc
    parameters = manifest.get("parameters")
    if not isinstance(parameters, dict) or set(parameters) - {"languages", "outputs"}:
        raise AppError("不支持所选 OCR 参数。", "invalid")
    if "languages" in parameters and (not parameters["languages"] or not validate_languages(parameters["languages"])):
        raise AppError("交接语言列表无效。", "invalid")
    outputs = parameters.get("outputs", ["text", "json"])
    if not isinstance(outputs, list) or not outputs or len(outputs) > 256 or not all(isinstance(item, str) and item in FORMATS for item in outputs):
        raise AppError("交接输出格式无效。", "invalid")
    formats = list(dict.fromkeys(outputs))
    items = manifest.get("items")
    if manifest.get("references") != [] or not isinstance(items, list) or not 1 <= len(items) <= MAX_PAGES or len(formats) * len(items) > 256:
        raise AppError("OCR 请求须指定图像或 PDF 附件，且输出最多 256 份，请按需分批。", "invalid")
    paths, ids, total = set(), set(), 0
    for item in items:
        if not isinstance(item, dict):
            raise AppError("交接附件无效。", "invalid")
        parts = _parts(item.get("relativePath"))
        normalized = "/".join(parts).casefold()
        identifier_value = item.get("id")
        sha, size, uti = item.get("sha256"), item.get("byteCount"), item.get("uti")
        if (not isinstance(identifier_value, str) or not identifier_value or len(identifier_value.encode("utf-8")) > 256
                or identifier_value in ids or normalized in paths or not isinstance(uti, str) or uti not in TYPES
                or not isinstance(sha, str) or not SHA.fullmatch(sha) or type(size) is not int or not 0 <= size <= MAX_INPUT_BYTES):
            raise AppError("交接附件重复、无效或超过单文件 128 MiB 限制。", "invalid")
        ids.add(identifier_value)
        paths.add(normalized)
        total += size
    if total > MAX_PAYLOAD_BYTES:
        raise AppError("交接附件超过总容量限制。", "invalid")
    return manifest, identifier, digest, formats, total


class OcrProvider:
    def __init__(self, directory: Path, clock=None, session_factory=OcrSession, *, return_root: Path | None = None):
        self.root = Path(directory).resolve() / "OcrProvider"
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self.session_factory = session_factory
        self.return_root = Path(return_root) if return_root is not None else default_return_root()

    def receive(self, source: Path) -> dict:
        if source.suffix.casefold() != ".gaoaction":
            raise AppError("请选择 .gaoaction 交接包目录。", "invalid")
        try:
            source = source.parent.resolve(strict=True) / source.name
            manifest, identifier, digest, formats, total = _manifest(source, self.clock())
            destination = self.root / identifier
            if destination.exists():
                record = self._record(destination)
                if record["manifestSHA256"] != digest:
                    raise AppError("相同编号的 OCR 请求含不同的清单。", "conflict")
                return self._summary(record)
            self._check_budget(total)
            payload = source / "payload"
            _regular(payload, directory=True)
            self.root.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".incoming-", dir=self.root) as work:
                staged = Path(work) / "job"
                staged.mkdir()
                for index, item in enumerate(manifest["items"]):
                    components = _parts(item["relativePath"])
                    original = payload
                    for component in components[:-1]:
                        original /= component
                        _regular(original, directory=True)
                    target = self._input_path(staged, index, item["uti"])
                    _, size, item_digest = _read(original / components[-1], item["byteCount"], target)
                    if size != item["byteCount"] or item_digest != item["sha256"]:
                        raise AppError("交接附件大小或摘要不匹配。", "changed")
                record = {"schemaVersion": 1, "internalID": identifier, "manifest": manifest, "manifestSHA256": digest,
                          "formats": formats, "status": "pending", "inputBytes": total}
                self._write_record(staged, record)
                staged.rename(destination)
            return self._summary(record)
        except OSError as exc:
            raise AppError("无法读取或暂存交接包。", "rejected") from exc

    def approve(self, request_id, confirm) -> dict:
        if confirm is not True:
            raise AppError("请在复核来源与附件后确认识别。", "unauthorized")
        folder = self.root / _request_uuid(request_id)
        record = self._record(folder)
        if record["status"] != "pending":
            return self._summary(record)
        reservation = folder / "approval.lock"
        try:
            with reservation.open("xb"):
                pass
        except FileExistsError:
            return {**self._summary(self._record(folder)), "status": "interrupted"}
        except OSError as exc:
            raise AppError("无法保留本次交接执行状态。", "rejected") from exc
        try:
            return self._approve_reserved(folder)
        finally:
            reservation.unlink(missing_ok=True)

    def _approve_reserved(self, folder) -> dict:
        record = self._record(folder)
        manifest = record["manifest"]
        if record["status"] != "pending":
            return self._summary(record)
        _fresh(manifest, self.clock())
        staged, names = [], []
        for index, item in enumerate(manifest["items"]):
            path = self._input_path(folder, index, item["uti"])
            _, count, digest = self._check_item(path, item)
            if count != item["byteCount"] or digest != item["sha256"]:
                raise AppError("已复核的附件于执行前发生变化。", "changed")
            staged.append(path)
            names.append(_parts(item["relativePath"])[-1])
        record["status"] = "executing"
        self._write_record(folder, record)
        try:
            recognizer = self.session_factory()
            doc = recognizer.recognize_paths(staged, manifest["parameters"].get("languages"), names=names,
                                             retain_rasters="searchablePDF" in record["formats"])
            record["status"] = doc["status"]
            record["result"], record["provenance"] = self._export_work(folder, record, recognizer, doc)
            if record["status"] == "completed" and record["provenance"]["exportFailures"]:
                record["status"] = "partial" if record["result"] else "failed"
            record["errorCode"] = None if record["status"] == "completed" else "pageOrExportFailed"
        except (AppError, OSError) as exc:
            record["status"] = "failed"
            record["errorCode"] = exc.code if isinstance(exc, AppError) else "failed"
            record["result"] = []
            record["provenance"] = {"engine": ENGINE, "networkUsed": False, "sources": [], "outputs": [],
                                    "exportFailures": [exc.message if isinstance(exc, AppError) else "结果暂存失败。"]}
        self._write_record(folder, record)
        return self._try_return(folder, record)

    @staticmethod
    def _supports_return(record):
        manifest = record["manifest"]
        identifier = record["internalID"]
        digest = record.get("manifestSHA256")
        return (manifest["sourceBundleID"] in RETURN_SOURCES and manifest["requestID"] == identifier
                and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", identifier)
                and isinstance(digest, str) and SHA.fullmatch(digest))

    @contextmanager
    def _return_ticket(self, directory, record):
        original = record["manifest"]
        _fresh(original, self.clock())
        ticket = directory / "request.json"
        with _open_windows_file(ticket) as stream:
            snapshot = _file_snapshot(stream, ticket)
            if snapshot[0] > MAX_RETURN_TICKET_BYTES:
                raise ValueError("ticket size")
            raw = stream.read(MAX_RETURN_TICKET_BYTES + 1)
            if len(raw) != snapshot[0] or snapshot != _file_snapshot(stream, ticket):
                raise ValueError("ticket changed")
            _check_current_path(ticket, snapshot)

            def unique(pairs):
                values = dict(pairs)
                if len(values) != len(pairs):
                    raise ValueError("duplicate ticket keys")
                return values

            actual = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
            expected = {"schemaVersion": 1, "requestID": record["internalID"], "action": "ocr.files",
                        "sourceBundleID": original["sourceBundleID"], "targetBundleID": BUNDLE_ID,
                        "requestManifestSHA256": record["manifestSHA256"], "expiresAt": original["expiresAt"]}
            if actual != expected or type(actual["schemaVersion"]) is not int:
                raise ValueError("ticket binding")

            def recheck():
                _fresh(original, self.clock())
                if snapshot != _file_snapshot(stream, ticket):
                    raise ValueError("ticket changed")
                _check_current_path(ticket, snapshot)

            yield recheck

    def return_result(self, request_id) -> dict:
        folder = self.root / _request_uuid(request_id)
        return self._try_return(folder, self._record(folder))

    def _try_return(self, folder, record):
        if record["status"] != "completed" or not record.get("result") or not self._supports_return(record):
            return self._summary(record)
        try:
            _fresh(record["manifest"], self.clock())
            slot = self.return_root / record["internalID"] if self.return_root is not None else None
            with pinned_path(slot, exact_name=True, writable_parent=True) as directory, self._return_ticket(directory, record) as recheck:
                descriptor = record.get("returnDescriptor")
                if descriptor is None:
                    descriptor = record["returnDescriptor"] = self._result_identity()
                    # Persist the result identity before publishing so a retry can recognize our own result.
                    self._write_record(folder, record)
                result, blob = self._result_manifest(record, descriptor)
                destination = directory / "result.gaoaction"
                self._publish_return(folder, directory, destination, result, blob, recheck)
            status = "published"
        except AppError as exc:
            status = "expired" if exc.code == "expired" else "unavailable"
        except (OSError, ValueError):
            status = "unavailable"
        if record.get("returnStatus") != status:
            record["returnStatus"] = status
            try:
                self._write_record(folder, record)
            except AppError:
                # OCR artifacts and their result identity were committed before publication.
                pass
        return self._summary(record)

    def _publish_return(self, folder, directory, destination, result, blob, recheck):
        try:
            self._verify_published(destination, result, blob, recheck)
            return
        except FileNotFoundError:
            # Only absence of the destination itself permits publication. A malformed existing package does not.
            try:
                destination.lstat()
            except FileNotFoundError:
                pass
            else:
                self._verify_published(destination, result, blob, recheck)
                return
        with pinned_path(folder / "outputs"), tempfile.TemporaryDirectory(prefix=".return-", dir=directory) as work:
            staging = Path(work)
            with pinned_directory(staging, rename=True) as handle:
                self._write_package(folder, staging, result, blob, sync=True)
                with pinned_path(directory, exact_name=True, writable_parent=True):
                    recheck()
                    try:
                        rename_directory(handle, destination)
                    except OSError:
                        self._verify_published(destination, result, blob, recheck)

    def _verify_published(self, destination, result, blob, recheck):
        with pinned_directory(destination):
            payload = destination / "payload"
            with pinned_directory(payload):
                existing, _, _ = _read(destination / "manifest.json", MAX_MANIFEST_BYTES)
                if (existing != blob or {entry.name for entry in destination.iterdir()} != {"manifest.json", "payload"}
                        or {entry.name for entry in payload.iterdir()} != {item["relativePath"] for item in result["items"]}):
                    raise ValueError("different existing return")
                for item in result["items"]:
                    self._verify_result_item(payload, item)
                recheck()

    def export_result(self, request_id, directory: Path, confirm) -> dict:
        if confirm is not True:
            raise AppError("请确认导出当前任务结果。", "unauthorized")
        folder = self.root / _request_uuid(request_id)
        record = self._record(folder)
        if record["status"] not in {"completed", "partial", "failed"}:
            raise AppError("此请求还没有可导出的业务结果。", "pending")
        result, blob = self._result_manifest(record, self._result_identity())
        try:
            directory.mkdir(parents=True, exist_ok=True)
            directory = directory.resolve(strict=True)
            destination = directory / f"OCR-{result['requestID']}.gaoaction"
            with tempfile.TemporaryDirectory(prefix=".gaocaozuo-result-", dir=directory) as work:
                staging = Path(work) / "result"
                staging.mkdir()
                self._write_package(folder, staging, result, blob)
                staging.rename(destination)
            return {"path": str(destination), "requestID": result["requestID"], "inReplyTo": result["inReplyTo"], "status": record["status"]}
        except OSError as exc:
            raise AppError("交接结果未能写入所选目录。", "rejected") from exc

    def _result_identity(self):
        now = self.clock()
        return {"requestID": str(uuid.uuid4()), "createdAt": _stamp(now), "expiresAt": _stamp(now + timedelta(seconds=120)),
                "nonce": base64.b64encode(secrets.token_bytes(32)).decode("ascii")}

    @staticmethod
    def _result_manifest(record, identity):
        original = record["manifest"]
        result = {"schemaVersion": 1, "kind": "result", "requestID": identity["requestID"], "inReplyTo": original["requestID"],
                  "sourceBundleID": BUNDLE_ID, "targetBundleID": original["sourceBundleID"], "action": "ocr.files",
                  "createdAt": identity["createdAt"], "expiresAt": identity["expiresAt"], "nonce": identity["nonce"],
                  "items": record["result"], "references": [], "parameters": original["parameters"], "status": record["status"],
                  "errorCode": record.get("errorCode"), "provenance": {**record["provenance"], "requestManifestSHA256": record["manifestSHA256"]}}
        blob = json.dumps(result, ensure_ascii=False, indent=2).encode("utf-8")
        if len(blob) > MAX_MANIFEST_BYTES:
            raise AppError("结果清单超过 1 MiB，请分批识别。", "invalid")
        return result, blob

    def _write_package(self, folder, staging, result, blob, *, sync=False):
        target = staging / "payload"
        target.mkdir()
        with pinned_directory(target) if sync else nullcontext():
            for item in result["items"]:
                self._verify_result_item(folder / "outputs", item, target, sync=sync)
        manifest = staging / "manifest.json"
        if sync:
            with manifest.open("xb") as stream:
                stream.write(blob)
                stream.flush()
                os.fsync(stream.fileno())
        else:
            write_new(manifest, blob)

    def _verify_result_item(self, source, item, target=None, *, sync=False):
        basename = item["relativePath"]
        if len(_parts(basename)) != 1:
            raise AppError("保留结果中的附件路径无效。", "unsafe")
        _, count, digest = self._check_item(source / basename, item, target / basename if target else None, sync=sync)
        if count != item["byteCount"] or digest != item["sha256"]:
            raise AppError("待导出的附件摘要不匹配。", "changed")

    def jobs(self) -> list[dict]:
        jobs = []
        for folder in self.root.glob("[0-9a-f]*"):
            if not folder.is_dir():
                continue
            try:
                jobs.append(self._summary(self._record(folder)))
            except AppError:
                continue
        return sorted(jobs, key=lambda job: job["createdAt"], reverse=True)

    def _export_work(self, folder, record, recognizer, document):
        attachments, sources, outputs, failures = [], [], [], []
        total = 0
        for index, (source, staged) in enumerate(zip(document["sources"], record["manifest"]["items"])):
            source_id = str(uuid.uuid4())
            mapping = {"sourceID": source_id, "sourceItemID": staged["id"], "sourceSHA256": staged["sha256"]}
            if source.get("sha256") is not None and source["sha256"] != staged["sha256"]:
                raise AppError("识别输入摘要与批准的附件不匹配。", "changed")
            output_ids = []
            for format in record["formats"]:
                try:
                    artifact = recognizer.source_export(document["id"], format, index)
                    if total + len(artifact) > MAX_PAYLOAD_BYTES:
                        raise AppError("结果容量超过 2 GiB。", "invalid")
                    extension, uti = FORMATS[format]
                    basename, result_id = f"OCR-{index + 1}.{extension}", str(uuid.uuid4())
                    write_new(folder / "outputs" / basename, artifact)
                    total += len(artifact)
                    attachments.append({"id": result_id, "relativePath": basename, "uti": uti,
                                        "byteCount": len(artifact), "sha256": hashlib.sha256(artifact).hexdigest()})
                    output_ids.append(result_id)
                    outputs.append({**mapping, "resultItemID": result_id, "format": format})
                except AppError as exc:
                    failures.append(f"第 {index + 1} 项 {format} · {exc.message}")
            sources.append({**mapping, "outputItemIDs": output_ids, "pages": [{"pageNumber": page["page"],
                "status": page["status"], "elapsedSeconds": page.get("elapsedSeconds", 0),
                "lineCount": len(page["lines"]), "failureReason": page["error"]} for page in source["pages"]]})
        return attachments, {"sources": sources, "outputs": outputs, "engine": ENGINE, "networkUsed": False,
                             "exportFailures": failures}

    def _check_budget(self, extra):
        jobs = list(self.root.glob("[0-9a-f]*"))
        if len(jobs) >= MAX_PENDING:
            raise AppError("已达到 128 个留存交接任务的上限。", "invalid")
        for folder in jobs:
            record = self._record(folder)
            extra += record["inputBytes"] + sum(item["byteCount"] for item in record.get("result", []))
        if extra > MAX_STORE_BYTES:
            raise AppError("已达到交接资料留存上限。", "invalid")

    def _record(self, folder):
        try:
            data, _, _ = _read(self.root.resolve() / folder.name / "journal.json", 2 * MAX_MANIFEST_BYTES)
            record = json.loads(data.decode("utf-8"))
            if record.get("schemaVersion") != 1 or record.get("internalID") != folder.name:
                raise ValueError
            return record
        except FileNotFoundError as exc:
            raise AppError("找不到这份 OCR 交接请求。", "missing") from exc
        except (AttributeError, OSError, ValueError) as exc:
            raise AppError("交接任务记录损坏或版本不受支持。", "invalid") from exc

    def _write_record(self, folder, record):
        try:
            atomic_replace(folder / "journal.json", json.dumps(record, ensure_ascii=False, indent=2).encode("utf-8"))
        except OSError as exc:
            raise AppError("无法保存交接任务状态。", "rejected") from exc

    def _summary(self, record):
        manifest = record["manifest"]
        return {"requestID": manifest["requestID"], "status": "interrupted" if record["status"] == "executing" else record["status"],
                "action": "ocr.files", "sourceBundleID": manifest["sourceBundleID"], "createdAt": manifest["createdAt"],
                "expiresAt": manifest["expiresAt"], "parameters": manifest["parameters"],
                "resultCount": len(record.get("result", [])), "errorCode": record.get("errorCode"),
                "errors": record.get("provenance", {}).get("exportFailures", []),
                "autoReturn": {"targetBundleID": manifest["sourceBundleID"], "status": self._return_status(record)},
                "items": [{"name": _parts(item["relativePath"])[-1], "byteCount": item["byteCount"], "uti": item["uti"]}
                          for item in manifest["items"]]}

    def _return_status(self, record):
        if not self._supports_return(record):
            return "notEligible"
        if record["status"] == "completed" and record.get("result"):
            return record.get("returnStatus", "unavailable")
        if record["status"] != "pending":
            return "notEligible"
        try:
            _fresh(record["manifest"], self.clock())
            slot = self.return_root / record["internalID"] if self.return_root is not None else None
            with pinned_path(slot, exact_name=True) as directory, self._return_ticket(directory, record):
                return "ready"
        except AppError as exc:
            return "expired" if exc.code == "expired" else "unavailable"
        except (OSError, ValueError):
            return "unavailable"

    @staticmethod
    def _input_path(folder, index, uti):
        return folder / f"input-{index + 1}{'.pdf' if uti in PDF_TYPES else '.bin'}"

    @staticmethod
    def _check_item(path, item, target=None, *, sync=False):
        try:
            return _read(path, item["byteCount"], target, collect=False, sync=sync)
        except OSError as exc:
            raise AppError("交接附件无法重新核对。", "rejected") from exc
