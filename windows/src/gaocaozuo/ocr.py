"""Local Windows OCR and searchable exports."""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
import re
import subprocess
import tempfile
import uuid
from pathlib import Path

from PIL import Image

from gaocaozuo.errors import AppError
from gaocaozuo.resources import asset_dir
from gaocaozuo.screenshot import MAX_INPUT_BYTES, encode_image, read_image, write_new

ENGINE = "Windows.Media.Ocr"
FORMATS = {"text": ("txt", "public.utf8-plain-text"), "markdown": ("md", "net.daringfireball.markdown"),
           "json": ("json", "public.json"), "searchablePDF": ("pdf", "com.adobe.pdf")}
MAX_PAGES = 200
MAX_RASTER_BYTES = 80 * 1024 * 1024
MAX_PIXELS = 12_000_000
LANGUAGE = re.compile(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*\Z", re.ASCII)


def validate_languages(languages) -> list[str]:
    if languages is None:
        return []
    if not isinstance(languages, list) or len(languages) > 12 or not all(isinstance(value, str) and len(value) <= 63 and LANGUAGE.fullmatch(value) for value in languages):
        raise AppError("识别语言参数无效，一次最多选择 12 种已安装的语言。", "invalid")
    return list(dict.fromkeys(languages))


def status_for(sources: list[dict]) -> str:
    pages = [page for source in sources for page in source["pages"]]
    completed = sum(page["status"] == "completed" for page in pages)
    if not completed:
        return "failed"
    return "completed" if completed == len(pages) else "partial"


def _helper_binary() -> Path:
    name = "GaoCaoZuo-WinOcr.exe"
    choices = [asset_dir() / name, Path(__file__).resolve().parents[2] / "build" / "ocr" / name]
    path = next((item for item in choices if item.is_file()), None)
    if path is None or os.name != "nt":
        raise AppError("未找到 Windows 本机 OCR 组件。请使用完整安装包。", "unavailable")
    return path


def _invoke(request: dict) -> dict:
    try:
        process = subprocess.run([str(_helper_binary())], input=json.dumps(request).encode("utf-8"), capture_output=True,
                                 timeout=180, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False)
        result = json.loads(process.stdout.decode("utf-8"))
    except subprocess.TimeoutExpired as exc:
        raise AppError("本机识别超时，请将文件分成较小批次。", "timeout") from exc
    except (OSError, ValueError) as exc:
        raise AppError("Windows 本机 OCR 组件没有返回有效响应。", "unavailable") from exc
    if not isinstance(result, dict) or process.returncode and "error" not in result:
        raise AppError("Windows 本机 OCR 组件没有返回有效响应。", "unavailable")
    error = result.get("error")
    if error:
        if error.startswith("OCR_LANGUAGE_MISSING"):
            tag = error.partition(":")[2]
            suffix = f"（{tag}）" if tag else ""
            raise AppError(f"未安装可用的 Windows OCR 语言{suffix}。可在系统语言设置中添加。", "missingLanguage")
        if error == "OCR_PAGE_LIMIT":
            raise AppError("PDF 页数超过本批处理限制或没有页面。", "pageLimit")
        raise AppError("Windows 无法打开或识别所选文件。", "recognitionFailed")
    return result


def _normalized(image: Image.Image) -> Image.Image:
    if image.width * image.height <= MAX_PIXELS and max(image.size) <= 10_000:
        return image
    scale = min(10_000 / max(image.size), math.sqrt(MAX_PIXELS / (image.width * image.height)))
    return image.resize(tuple(max(1, int(length * scale)) for length in image.size), Image.Resampling.LANCZOS)


def _copy_with_digest(path: Path, target: Path, maximum=MAX_INPUT_BYTES) -> tuple[int, str]:
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as original, target.open("xb") as copy:
        before = os.fstat(original.fileno())
        if before.st_size > maximum:
            raise AppError("OCR 输入超过单文件 128 MiB 限制。", "invalid")
        while chunk := original.read(1024 * 1024):
            total += len(chunk)
            if total > maximum:
                raise AppError("OCR 输入超过单文件 128 MiB 限制。", "invalid")
            digest.update(chunk)
            copy.write(chunk)
        after = os.fstat(original.fileno())
        if before.st_size != total or before.st_mtime_ns != after.st_mtime_ns or before.st_size != after.st_size:
            raise AppError("读取时文件发生变化，请重新选择。", "changed")
    return total, digest.hexdigest()


def _failure(detail: str) -> dict:
    return {"page": 1, "status": "failed", "text": "", "lines": [], "error": detail, "elapsedSeconds": 0}


class OcrSession:
    def __init__(self):
        self._document = None
        self._rasters = {}

    def languages(self) -> dict:
        return _invoke({"operation": "languages"})

    def recognize_image(self, name: str, image: Image.Image, languages=None) -> dict:
        tags = validate_languages(languages)
        with tempfile.TemporaryDirectory(prefix="gaocaozuo-ocr-") as scratch:
            source = Path(scratch) / "input.png"
            blob = encode_image(image)
            prepared = _normalized(image)
            source.write_bytes(blob if image is prepared else encode_image(prepared))
            pages = self._recognize(source, tags, False, 1)
            return self._remember([{"name": name, "sha256": hashlib.sha256(blob).hexdigest(), "byteCount": len(blob), "pages": pages}], {(0, 1): encode_image(prepared, "JPEG")})

    def recognize_paths(self, paths, languages=None, *, names=None, retain_rasters=True) -> dict:
        tags = validate_languages(languages)
        if not isinstance(paths, (list, tuple)) or not 1 <= len(paths) <= MAX_PAGES:
            raise AppError("请选择 1 至 200 个本机图像或 PDF 文件。", "invalid")
        sources, rasters = [], {}
        remaining_pages = MAX_PAGES
        remaining_raster_bytes = MAX_RASTER_BYTES
        for index, value in enumerate(paths):
            try:
                path = Path(value)
            except TypeError as exc:
                raise AppError("OCR 输入路径无效。", "invalid") from exc
            source = {"name": names[index] if names else path.name, "sha256": None, "byteCount": None, "pages": []}
            sources.append(source)
            with tempfile.TemporaryDirectory(prefix="gaocaozuo-ocr-") as scratch:
                staging = Path(scratch)
                try:
                    if not remaining_pages:
                        raise AppError("本批已经达到 200 页限制，请分批识别。", "pageLimit")
                    if not path.is_file():
                        raise AppError("所选对象无法读取为普通文件。", "missing")
                    pdf = path.suffix.casefold() == ".pdf"
                    prepared = staging / ("input.pdf" if pdf else "source.bin")
                    count, digest = _copy_with_digest(path, prepared)
                    source.update(sha256=digest, byteCount=count)
                    if not pdf:
                        image = _normalized(read_image(prepared))
                        prepared = staging / "input.png"
                        prepared.write_bytes(encode_image(image))
                    pages = self._recognize(prepared, tags, pdf, remaining_pages, staging if retain_rasters and remaining_raster_bytes else None)
                    source["pages"] = pages
                    remaining_pages -= len(pages)
                    for page in pages:
                        if not retain_rasters or not remaining_raster_bytes or page["status"] != "completed":
                            continue
                        number = page["page"]
                        rendered = staging / f"page-{number}.png"
                        if pdf and not page.get("rasterAvailable"):
                            continue
                        try:
                            raster = encode_image(read_image(rendered) if pdf else image, "JPEG")
                        except (AppError, OSError):
                            continue
                        if len(raster) <= remaining_raster_bytes:
                            rasters[(index, number)] = raster
                            remaining_raster_bytes -= len(raster)
                except AppError as exc:
                    if exc.code in {"unavailable", "missingLanguage"}:
                        raise
                    source["pages"] = [_failure(exc.message)]
                except OSError:
                    source["pages"] = [_failure("无法读取当前文件。")]
        return self._remember(sources, rasters)

    def export(self, document_id, directory: Path, format: str) -> dict:
        payload = self.source_export(document_id, format)
        extension = FORMATS[format][0]
        path = directory / f"OCR-{document_id[:8]}.{extension}"
        return {"path": str(write_new(path, payload)), "format": format}

    def source_export(self, document_id: str, format: str, source_index: int | None = None) -> bytes:
        document = self._get(document_id)
        if format not in FORMATS:
            raise AppError("不支持所选 OCR 导出格式。", "invalid")
        indices = range(len(document["sources"])) if source_index is None else (source_index,)
        origins = [document["sources"][index] for index in indices]
        if format == "json":
            result = {**document, "sources": origins, "status": status_for(origins), "text": _document_text(origins)}
            return (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        if format == "searchablePDF":
            candidates = [(index, page) for index in indices for page in document["sources"][index]["pages"]]
            if not candidates or any((index, page["page"]) not in self._rasters for index, page in candidates):
                raise AppError("可搜索 PDF 需要每一页的原画面。请缩短批次或重试失败页。", "rasterMissing")
            return _searchable_pdf([(page, self._rasters[index, page["page"]]) for index, page in candidates])
        sections = []
        for source in origins:
            if format == "markdown":
                sections.append("## " + re.sub(r"[\r\n]+", " ", source["name"]))
            for page in source["pages"]:
                if format == "markdown":
                    sections.append(f"### 第 {page['page']} 页")
                sections.append(page["text"] if page["status"] == "completed" else "[识别失败] " + page["error"])
        return ("\n\n".join(sections) + "\n").encode("utf-8")

    def edit(self, document_id, source_index, page_number, line_index, text) -> dict:
        document = self._get(document_id)
        if any(type(value) is not int or value < 0 for value in (source_index, page_number, line_index)) or not isinstance(text, str) or not text or len(text) > 4000:
            raise AppError("校正内容或识别行位置无效。", "invalid")
        try:
            page = next(page for page in document["sources"][source_index]["pages"] if page["page"] == page_number)
            line = page["lines"][line_index]
            line.setdefault("originalText", line["text"])
            line["text"] = text
            page["text"] = "\n".join(line["text"] for line in page["lines"])
            document["text"] = _document_text(document["sources"])
            return document
        except (IndexError, StopIteration) as exc:
            raise AppError("没有所选识别行。", "missing") from exc

    def _get(self, document_id):
        if self._document is None or self._document["id"] != document_id:
            raise AppError("这份 OCR 结果已不在当前工作区。", "missing")
        return self._document

    def _recognize(self, path: Path, languages: list[str], pdf: bool, max_pages: int, render=None) -> list[dict]:
        result = _invoke({"operation": "recognize", "languages": languages, "path": str(path), "pdf": pdf,
                          "maxPages": max_pages, "renderDirectory": str(render) if render else None})
        pages = result["pages"]
        for page in pages:
            page["status"] = "failed" if page["error"] else "completed"
            if page["error"]:
                page["error"] = "Windows 无法渲染或识别此 PDF 页。"
        return pages

    def _remember(self, sources, rasters):
        self._rasters = rasters
        self._document = {"id": uuid.uuid4().hex, "schemaVersion": 1, "status": status_for(sources), "sources": sources,
                          "engine": ENGINE, "networkUsed": False, "text": _document_text(sources)}
        return self._document


def _document_text(sources):
    return "\n\n".join(page["text"] for source in sources for page in source["pages"] if page["status"] == "completed")


def _searchable_pdf(pages: list[tuple[dict, bytes]]) -> bytes:
    """Write raster pages and an invisible, position-anchored Unicode text layer."""
    characters = dict.fromkeys(char for page, _ in pages for line in page["lines"] for char in line["text"])
    if len(characters) > 65_534:
        raise AppError("可搜索 PDF 文字层包含过多不同字符，请分批导出。", "invalid")
    char_codes = {char: f"{index:04x}" for index, char in enumerate(characters, 1)}
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>", b"",
        b"<< /Type /Font /Subtype /Type0 /BaseFont /GaoOCR /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 6 0 R >>",
        b"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /GaoOCR /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 5 0 R /DW 1000 /CIDToGIDMap /Identity >>",
        b"<< /Type /FontDescriptor /FontName /GaoOCR /Flags 4 /FontBBox [0 -250 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 800 /StemV 80 >>",
        _pdf_unicode_map(char_codes),
    ]
    page_ids = []
    for page, image in pages:
        width, height = page["width"], page["height"]
        pw, ph = page.get("pageWidth") or width * .75, page.get("pageHeight") or height * .75
        sx, sy = pw / width, ph / height
        page_ref, image_ref, content_ref = len(objects) + 1, len(objects) + 2, len(objects) + 3
        page_ids.append(f"{page_ref} 0 R")
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pw:.4f} {ph:.4f}] /Contents {content_ref} 0 R /Resources << /XObject << /Im {image_ref} 0 R >> /Font << /F1 3 0 R >> >> >>".encode("ascii"))
        image_description = f"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
        objects.append(_pdf_stream(image, image_description))
        operations = [f"q {pw:.4f} 0 0 {ph:.4f} 0 0 cm /Im Do Q"]
        for line in page["lines"]:
            words = line["words"]
            if not words or not line["text"]:
                continue
            left = min(word["x"] for word in words) * sx
            right = max(word["x"] + word["width"] for word in words) * sx
            base = ph - max(word["y"] + word["height"] for word in words) * sy
            size = max(1, (max(word["y"] + word["height"] for word in words) - min(word["y"] for word in words)) * sy)
            raw = (b"\xfe\xff" + line["text"].encode("utf-16-be")).hex()
            encoded = "".join(char_codes[char] for char in line["text"])
            horizontal = 100 * max(1, right - left) / (len(line["text"]) * size)
            operations.append(f"/Span << /ActualText <{raw}> >> BDC BT /F1 {size:.4f} Tf 3 Tr {horizontal:.4f} Tz {left:.4f} {base:.4f} Td <{encoded}> Tj ET EMC")
        objects.append(_pdf_stream("\n".join(operations).encode("ascii")))
    objects[1] = f"<< /Type /Pages /Kids [{' '.join(page_ids)}] /Count {len(page_ids)} >>".encode("ascii")
    output = io.BytesIO()
    output.write(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, entry in enumerate(objects, 1):
        offsets.append(output.tell())
        output.write(f"{number} 0 obj\n".encode("ascii"))
        output.write(entry)
        output.write(b"\nendobj\n")
    xref = output.tell()
    output.write(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets[1:]:
        output.write(f"{offset:010d} 00000 n \n".encode("ascii"))
    output.write(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    return output.getvalue()


def _pdf_stream(content: bytes, description: str = "") -> bytes:
    return f"<< {description} /Length {len(content)} >>\nstream\n".encode("ascii") + content + b"\nendstream"


def _pdf_unicode_map(char_codes: dict[str, str]) -> bytes:
    entries = [f"<{code}> <{char.encode('utf-16-be').hex()}>" for char, code in char_codes.items()]
    cmap = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
            "/CMapName /GaoOCR-UCS def", "/CMapType 2 def",
            "1 begincodespacerange", "<0000> <ffff>", "endcodespacerange"]
    for position in range(0, len(entries), 100):
        chunk = entries[position:position + 100]
        cmap.extend((f"{len(chunk)} beginbfchar", *chunk, "endbfchar"))
    cmap.extend(("endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"))
    return _pdf_stream("\n".join(cmap).encode("ascii"))
