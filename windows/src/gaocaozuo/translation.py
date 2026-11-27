"""Verified Argos language packs and local CTranslate2 inference."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import os
import re
import shutil
import stat
import tempfile
import threading
import time
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable
from urllib.error import URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from gaocaozuo.errors import AppError


MAX_TEXT = 100_000
CHUNK_BYTES = 1024 * 1024
PACKAGE_TIMEOUT = 1800
SUPPORTED_NAMES = {"en": "英语", "zh": "简体中文"}
LABEL = "Argos Translate · CTranslate2"


@dataclass(frozen=True)
class ModelFile:
    name: str
    size: int
    digest: str


@dataclass(frozen=True)
class ModelPack:
    source: str
    target: str
    version: str
    size: int
    digest: str
    files: tuple[ModelFile, ...]

    @property
    def pair(self) -> str:
        return f"{self.source}-{self.target}"

    @property
    def dirname(self) -> str:
        return f"{self.pair}-{self.version}-{self.digest[:12]}"

    @property
    def archive_name(self) -> str:
        return f"translate-{self.source}_{self.target}-{self.version.replace('.', '_')}.argosmodel"

    @property
    def url(self) -> str:
        return f"https://data.argosopentech.com/argospm/v1/{self.archive_name}"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise AppError("官方语言包下载地址发生变化，未跟随跳转。", "downloadFailed")


def _open_package(url: str):
    opener = build_opener(NoRedirect())
    return opener.open(Request(url, headers={"Accept": "application/octet-stream", "User-Agent": "GaoCaoZuo/1.16"}), timeout=20)


def _ordinary(path: Path, kind: Callable[[int], bool]) -> bool:
    try:
        info = path.lstat()
        return kind(info.st_mode) and not getattr(info, "st_file_attributes", 0) & 0x400
    except OSError:
        return False


def _copy_exact(source, sink, size, digest, cancelled, advance=lambda _: None):
    sha256 = hashlib.sha256()
    count = 0
    while True:
        _check_cancelled(cancelled)
        chunk = source.read(CHUNK_BYTES)
        if not chunk:
            break
        count += len(chunk)
        if count > size:
            raise AppError("语言包数据超出已知大小。", "badModel")
        sha256.update(chunk)
        if sink is not None:
            sink.write(chunk)
        advance(count)
    if count != size or sha256.hexdigest() != digest:
        raise AppError("语言包数据与固定大小或 SHA-256 不符。", "badModel")


def _check_cancelled(cancelled):
    if cancelled.is_set():
        raise AppError("操作已取消。", "cancelled")


def _supported_runtime() -> bool:
    return os.name == "nt" and all(importlib.util.find_spec(module) for module in ("ctranslate2", "sentencepiece", "py3langid"))


def _language(code):
    if not isinstance(code, str):
        return ""
    code = code.replace("_", "-").lower()
    if code in {"zh-tw", "zh-hk", "zh-hant"}:
        return "zt"
    return code.split("-", 1)[0]


def _detect_language(text: str) -> str:
    import py3langid as langid

    sample = text[:8_192].strip()
    if sum(character.isalpha() for character in sample) < 5:
        raise AppError("原文太短，无法可靠检测语言。请选择原文语言。", "languageUnknown")
    top, second, *_ = langid.rank(sample)
    code, score = top
    if score - second[1] < 1.5 or code in {"", "zxx", "und"}:
        raise AppError("无法可靠检测原文语言。请选择原文语言。", "languageUnknown")
    return code


def _tokens_in_blocks(pieces: list[str], limit=128):
    start = 0
    while len(pieces) - start > limit:
        end = start + limit
        split = next((index for index in range(end, end - limit // 4, -1)
                      if pieces[index].startswith("▁") or pieces[index - 1].endswith(tuple("。！？，；.!?;"))), end)
        yield pieces[start:split]
        start = split
    if start < len(pieces):
        yield pieces[start:]


def _infer(files, text, target, cancelled):
    try:
        import ctranslate2
        import sentencepiece

        tokenizer = sentencepiece.SentencePieceProcessor(model_proto=files["sentencepiece.model"])
        engine_files = {name.removeprefix("model/"): content for name, content in files.items() if name.startswith("model/")}
        worker = ctranslate2.Translator("gaocaozuo-local-model", files=engine_files, device="cpu", inter_threads=1,
                                       intra_threads=min(os.cpu_count() or 1, 4), compute_type="auto")
        output = []
        joiner = "" if target in {"zh", "zt", "ja"} else " "
        for line in re.split(r"(\r\n|\r|\n)", text):
            _check_cancelled(cancelled)
            trimmed = line.strip()
            if not trimmed:
                output.append(line)
                continue
            segments = []
            for pieces in _tokens_in_blocks(tokenizer.encode(trimmed, out_type=str)):
                _check_cancelled(cancelled)
                translated = worker.translate_batch([pieces], beam_size=4, max_input_length=130, max_decoding_length=300)
                segments.append(tokenizer.decode(translated[0].hypotheses[0]))
            output.append(line[:len(line) - len(line.lstrip())] + joiner.join(segments) + line[len(line.rstrip()):])
        _check_cancelled(cancelled)
        result = "".join(output)
        if not result.strip():
            raise AppError("本机模型没有生成可用译文。", "translationFailed")
        return result
    except AppError:
        raise
    except (ImportError, OSError, RuntimeError, TypeError, ValueError, IndexError) as exc:
        raise AppError("本机翻译引擎或语言包无法加载，请检查安装。", "translationFailed") from exc


@dataclass
class _Job:
    id: str
    kind: str
    status: str = "running"
    stop: threading.Event = field(default_factory=threading.Event)
    total: int = 0
    completed: int = 0
    result: dict | None = None
    error: AppError | None = None
    ended: float | None = None

    def public(self) -> dict:
        result = {"jobId": self.id, "kind": self.kind, "status": self.status, "completedBytes": self.completed, "totalBytes": self.total}
        if self.result is not None:
            result["result"] = self.result
        if self.error is not None:
            result.update(error=self.error.message, code=self.error.code)
        return result


class LocalTranslation:
    def __init__(self, directory: Path, *, packs=None, opener=_open_package, infer=_infer, detect=_detect_language, runtime=_supported_runtime):
        if packs is None:
            from gaocaozuo.translation_models import PACKS

            packs = PACKS
        self.packs = {pack.pair: pack for pack in packs}
        self.languages = {code for pack in packs for code in (pack.source, pack.target)}
        self.directory = Path(directory) / "TranslationModels"
        self.opener = opener
        self.infer = infer
        self.detect = detect
        self.runtime = runtime
        self.lock = threading.Lock()
        self.jobs: dict[str, _Job] = {}
        self.worker: threading.Thread | None = None

    def catalog(self):
        available = self.runtime()
        return {"available": available, "reason": None if available else "本机翻译组件不可用。", "provider": LABEL,
                "languages": [{"code": code, "name": SUPPORTED_NAMES[code]} for code in sorted(self.languages)],
                "packs": [self._public_pack(pack) for pack in self.packs.values()]}

    def _public_pack(self, pack):
        path = self.directory / pack.dirname
        state = "installed" if self._files_exist(pack) else "damaged" if os.path.lexists(path) else "missing"
        return {"id": pack.pair, "source": pack.source, "target": pack.target, "size": pack.size,
                "version": pack.version, "sha256": pack.digest, "status": state}

    def _files_exist(self, pack):
        base = self.directory / pack.dirname
        if not all(_ordinary(path, stat.S_ISDIR) for path in (self.directory, base, base / "model")):
            return False
        try:
            return all(_ordinary(base / file.name, stat.S_ISREG) and (base / file.name).stat().st_size == file.size for file in pack.files)
        except OSError:
            return False

    def resolve(self, text, source, target):
        if not self.runtime():
            raise AppError("本机翻译组件不可用。", "unavailable")
        if not isinstance(text, str) or not text.strip():
            raise AppError("请输入要翻译的文字。", "invalid")
        if len(text) > MAX_TEXT:
            raise AppError("单次翻译限 100,000 个字符，请分段。", "budget")
        source_code, target_code = _language(source), _language(target)
        detected = source_code == "auto"
        if detected:
            source_code = self.detect(text)
        if source_code not in self.languages or target_code not in self.languages or source_code == target_code:
            raise AppError("当前语言组合不可用，请选择不同且受支持的语言。", "unsupportedPair")
        direct = self.packs.get(f"{source_code}-{target_code}")
        path = [direct] if direct else [self.packs.get(f"{source_code}-en"), self.packs.get(f"en-{target_code}")]
        if not all(path):
            raise AppError("没有这个语言组合的本机翻译模型。", "unsupportedPair")
        return {"source": source_code, "target": target_code, "detected": detected, "packs": [self._public_pack(pack) for pack in path],
                "pivot": "en" if len(path) > 1 else None}

    def start_download(self, pack_id, confirmed):
        if confirmed is not True:
            raise AppError("请先确认下载所选语言包。", "unauthorized")
        if not self.runtime():
            raise AppError("本机翻译组件不可用。", "unavailable")
        pack = self.packs.get(pack_id) if isinstance(pack_id, str) else None
        if not pack:
            raise AppError("请选择列出的语言包。", "invalid")
        return self._start("download", pack.size, lambda job: self._download(pack, job))

    def _download(self, pack, job):
        destination = self.directory / pack.dirname
        self.directory.mkdir(parents=True, exist_ok=True)
        if not _ordinary(self.directory, stat.S_ISDIR):
            raise AppError("语言包目录为链接或特殊位置。", "unsafe")
        if os.path.lexists(destination):
            self._check_pack(pack, job.stop)
            return self._public_pack(pack)
        with tempfile.TemporaryDirectory(prefix=".download-", dir=self.directory) as scratch:
            directory = Path(scratch)
            archive = directory / "download.argosmodel"
            started = time.monotonic()

            def progress(count):
                if time.monotonic() - started >= PACKAGE_TIMEOUT:
                    raise AppError("语言包下载超时。", "downloadFailed")
                with self.lock:
                    job.completed = count

            try:
                with self.opener(pack.url) as response, archive.open("xb") as output:
                    length = response.headers.get("Content-Length")
                    if length is not None and (not length.isdigit() or int(length) != pack.size):
                        raise AppError("官方语言包的大小与固定版本不符。", "badModel")
                    _copy_exact(response, output, pack.size, pack.digest, job.stop, progress)
            except (OSError, URLError) as exc:
                raise AppError("无法下载语言包，请检查网络后重试。", "downloadFailed") from exc
            unpacked = directory / "checked"
            (unpacked / "model").mkdir(parents=True)
            with zipfile.ZipFile(archive) as container:
                entries = container.infolist()
                archive_root = pack.archive_name.removesuffix(".argosmodel")
                for file in pack.files:
                    matches = [entry for entry in entries if entry.filename == f"{archive_root}/{file.name}"]
                    if len(matches) != 1 or matches[0].file_size != file.size or matches[0].is_dir() or stat.S_ISLNK(matches[0].external_attr >> 16):
                        raise AppError("语言包缺少唯一且有效的模型文件。", "badModel")
                    with container.open(matches[0]) as member, (unpacked / file.name).open("xb") as output:
                        _copy_exact(member, output, file.size, file.digest, job.stop)
            _check_cancelled(job.stop)
            unpacked.rename(destination)
        return self._public_pack(pack)

    def _check_pack(self, pack, cancelled, load=False):
        if not self._files_exist(pack):
            raise AppError("语言包缺失或损坏。请检查应用的 TranslationModels 目录。", "badModel")
        base = self.directory / pack.dirname
        verified = {}
        for file in pack.files:
            with (base / file.name).open("rb") as handle, io.BytesIO() as contents:
                _copy_exact(handle, contents if load else None, file.size, file.digest, cancelled)
                if load:
                    verified[file.name] = contents.getvalue()
        return verified

    def start_translation(self, text, source, target):
        plan = self.resolve(text, source, target)
        if any(item["status"] != "installed" for item in plan["packs"]):
            raise AppError("此语言组合需要先明确下载语言包。", "missingModel")

        def run(job):
            result = text
            for entry in plan["packs"]:
                pack = self.packs[entry["id"]]
                files = self._check_pack(pack, job.stop, load=True)
                result = self.infer(files, result, pack.target, job.stop)
                _check_cancelled(job.stop)
            return {"text": result, "source": plan["source"], "target": plan["target"], "detected": plan["detected"],
                    "provider": LABEL, "networkUsed": False, "contentSentToCloud": False}

        return self._start("translation", 0, run)

    def _start(self, kind, total, work):
        with self.lock:
            self._prune()
            if any(job.status in {"running", "cancelling"} for job in self.jobs.values()):
                raise AppError("请先完成或取消当前本机翻译操作。", "busy")
            job = _Job(uuid.uuid4().hex, kind, total=total)
            self.jobs[job.id] = job
            self.worker = threading.Thread(target=self._run, args=(job, work), name="gaocaozuo-local-translation", daemon=True)
            self.worker.start()
            return job.public()

    def _run(self, job, execute):
        result, error = None, None
        try:
            result = execute(job)
        except AppError as exc:
            # Retain only the public error. Its traceback can hold the input text and worker frame.
            error = AppError(exc.message, exc.code)
        except Exception:
            error = AppError("无法完成本机语言包操作。", "translationFailed")
        finally:
            with self.lock:
                job.ended = time.monotonic()
                if (job.stop.is_set() and job.kind == "translation") or (error and error.code == "cancelled"):
                    job.status = "cancelled"
                elif error:
                    job.error, job.status = error, "error"
                else:
                    job.result, job.status = result, "done"

    def _prune(self):
        expired = [key for key, job in self.jobs.items() if job.ended and time.monotonic() - job.ended >= 1200]
        for key in expired:
            del self.jobs[key]
        while len(self.jobs) > 8:
            self.jobs.pop(next(iter(self.jobs)))

    def job(self, identifier):
        with self.lock:
            self._prune()
            job = self.jobs.get(identifier) if isinstance(identifier, str) else None
            if not job:
                raise AppError("找不到该本机翻译任务。", "missing")
            return job.public()

    def cancel(self, identifier):
        with self.lock:
            job = self.jobs.get(identifier) if isinstance(identifier, str) else None
            if not job:
                raise AppError("找不到该本机翻译任务。", "missing")
            if job.status == "running":
                job.stop.set()
                job.status = "cancelling"
            return job.public()

    def close(self, *, wait=False):
        with self.lock:
            for job in self.jobs.values():
                if job.status in {"running", "cancelling"}:
                    job.stop.set()
            worker = self.worker
        if worker:
            worker.join(timeout=None if wait else 1.0)

    def dispatch(self, endpoint, payload):
        text, source, target = (payload.get(key, default) for key, default in (("text", ""), ("source", "auto"), ("target", "en")))
        if endpoint == "catalog":
            return self.catalog()
        if endpoint == "plan":
            return self.resolve(text, source, target)
        if endpoint == "download":
            return self.start_download(payload.get("packId"), payload.get("confirm"))
        if endpoint == "job":
            return self.job(payload.get("jobId"))
        if endpoint == "cancel":
            return self.cancel(payload.get("jobId"))
        if endpoint == "translate":
            return self.start_translation(text, source, target)
        raise AppError("未知的本机翻译操作。", "invalid")
