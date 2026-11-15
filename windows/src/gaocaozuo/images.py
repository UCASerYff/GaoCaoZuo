"""PNG / BMP 读写、缩放，以及空白 Office 文档。不解码 JPEG、HEIC、TIFF。"""

from __future__ import annotations

import struct
import zipfile
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

from gaocaozuo.errors import AppError

MAX_PIXELS = 100_000_000


def _chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def encode_png(width: int, height: int, rgb: bytes) -> bytes:
    if width <= 0 or height <= 0 or len(rgb) != width * height * 3:
        raise AppError("图片数据尺寸不匹配。", "invalid")
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(rgb[y * stride : (y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _chunk(b"IEND", b"")


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(data: bytes) -> tuple[int, int, bytes]:
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AppError("不是 PNG 文件。", "unsupported")
    pos = 8
    width = height = None
    color = depth = interlace = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        tag = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if comp != 0 or filt != 0 or interlace != 0 or depth != 8 or color not in {0, 2, 6}:
                raise AppError("只读取 8 位、非隔行的灰阶或真彩 PNG。", "unsupported")
        elif tag == b"IDAT":
            idat.extend(chunk)
        elif tag == b"IEND":
            break
    if width is None or height is None or width <= 0 or height <= 0:
        raise AppError("PNG 缺少尺寸。", "invalid")
    if width * height > MAX_PIXELS:
        raise AppError("图片超过 1 亿像素预算。", "invalid")
    channels = {0: 1, 2: 3, 6: 4}[color]
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    expected = (stride + 1) * height
    if len(raw) < expected:
        raise AppError("PNG 数据不完整。", "invalid")
    rows: list[bytearray] = []
    offset = 0
    for _ in range(height):
        filt = raw[offset]
        row = bytearray(raw[offset + 1 : offset + 1 + stride])
        prior = rows[-1] if rows else bytearray(stride)
        if filt == 1:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + left) & 255
        elif filt == 2:
            for i in range(stride):
                row[i] = (row[i] + prior[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + prior[i]) // 2)) & 255
        elif filt == 4:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                up_left = prior[i - channels] if i >= channels else 0
                row[i] = (row[i] + _paeth(left, prior[i], up_left)) & 255
        elif filt != 0:
            raise AppError("PNG 过滤方式不受支持。", "unsupported")
        rows.append(row)
        offset += stride + 1
    rgb = bytearray()
    for row in rows:
        for x in range(width):
            if channels == 1:
                value = row[x]
                rgb.extend((value, value, value))
            else:
                i = x * channels
                rgb.extend(row[i : i + 3])
    return width, height, bytes(rgb)


def encode_bmp(width: int, height: int, rgb: bytes) -> bytes:
    if len(rgb) != width * height * 3:
        raise AppError("图片数据尺寸不匹配。", "invalid")
    row_stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    for y in range(height - 1, -1, -1):
        start = y * width * 3
        row = bytearray()
        for x in range(width):
            r, g, b = rgb[start + x * 3 : start + x * 3 + 3]
            row.extend((b, g, r))
        row.extend(b"\x00" * (row_stride - width * 3))
        pixels.extend(row)
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    return header + info + pixels


def decode_bmp(data: bytes) -> tuple[int, int, bytes]:
    if len(data) < 54 or data[:2] != b"BM":
        raise AppError("不是 BMP 文件。", "unsupported")
    offset = struct.unpack_from("<I", data, 10)[0]
    header = struct.unpack_from("<IiiHHI", data, 14)
    _size, width, height, planes, bit_count, _comp = header
    if planes != 1 or bit_count != 24 or width <= 0 or abs(height) <= 0:
        raise AppError("只读取 24 位未压缩 BMP。", "unsupported")
    top_down = height < 0
    height = abs(height)
    if width * height > MAX_PIXELS:
        raise AppError("图片超过 1 亿像素预算。", "invalid")
    row_stride = (width * 3 + 3) & ~3
    rgb = bytearray(width * height * 3)
    for row in range(height):
        src = offset + row * row_stride
        y = row if top_down else height - 1 - row
        for x in range(width):
            b, g, r = data[src + x * 3 : src + x * 3 + 3]
            dest = (y * width + x) * 3
            rgb[dest : dest + 3] = bytes((r, g, b))
    return width, height, bytes(rgb)


def load_image(path: Path) -> tuple[int, int, bytes]:
    data = Path(path).read_bytes()
    if data.startswith(b"\x89PNG"):
        return decode_png(data)
    if data.startswith(b"BM"):
        return decode_bmp(data)
    raise AppError(f"Windows 版只能读取 PNG 和 BMP：{Path(path).name}", "unsupported")


def scale(width: int, height: int, rgb: bytes, max_edge: int | None) -> tuple[int, int, bytes]:
    if max_edge is None:
        return width, height, rgb
    if not (1 <= max_edge <= 32768):
        raise AppError("最长边须在 1–32768 像素之间。", "invalid")
    longest = max(width, height)
    if longest <= max_edge:
        return width, height, rgb
    ratio = max_edge / longest
    new_w = max(1, int(round(width * ratio)))
    new_h = max(1, int(round(height * ratio)))
    out = bytearray(new_w * new_h * 3)
    for y in range(new_h):
        sy = min(height - 1, int(y * height / new_h))
        for x in range(new_w):
            sx = min(width - 1, int(x * width / new_w))
            src = (sy * width + sx) * 3
            dest = (y * new_w + x) * 3
            out[dest : dest + 3] = rgb[src : src + 3]
    return new_w, new_h, bytes(out)


def draw_rect(width: int, height: int, rgb: bytes, x: int, y: int, w: int, h: int, color: tuple[int, int, int]) -> bytes:
    pixels = bytearray(rgb)
    for py in range(max(0, y), min(height, y + h)):
        for px in range(max(0, x), min(width, x + w)):
            edge = py in {y, y + h - 1} or px in {x, x + w - 1}
            if edge:
                dest = (py * width + px) * 3
                pixels[dest : dest + 3] = bytes(color)
    return bytes(pixels)


def stitch_vertical(images: list[tuple[int, int, bytes]], overlap: int) -> tuple[int, int, bytes]:
    if not images:
        raise AppError("没有可拼接的图片。", "invalid")
    if overlap < 0:
        raise AppError("重叠像素不能为负。", "invalid")
    width = images[0][0]
    rows = []
    total = 0
    for index, (w, h, rgb) in enumerate(images):
        if w != width:
            raise AppError("拼接图片的宽度必须相同。", "invalid")
        start = overlap if index else 0
        if start >= h:
            raise AppError("重叠大于图片高度。", "invalid")
        rows.append(rgb[start * width * 3 :])
        total += h - start
    if width * total > MAX_PIXELS:
        raise AppError("拼接结果超过 1 亿像素预算。", "invalid")
    return width, total, b"".join(rows)


def _xml(path: str, text: str) -> tuple[str, str]:
    return path, text


def blank_office(kind: str) -> tuple[str, bytes]:
    creator = "<dc:creator></dc:creator><cp:lastModifiedBy></cp:lastModifiedBy>"
    core = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/dc/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">{creator}<dc:title></dc:title></cp:coreProperties>"""
    if kind == "docx":
        name = "docx"
        content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"""
        rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"""
        document = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/><w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>"""
        parts = [_xml("[Content_Types].xml", content_types), _xml("_rels/.rels", rels), _xml("word/document.xml", document), _xml("docProps/core.xml", core)]
    elif kind == "xlsx":
        name = "xlsx"
        content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"""
        rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"""
        workbook = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"""
        workbook_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""
        sheet = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData></sheetData></worksheet>"""
        parts = [
            _xml("[Content_Types].xml", content_types),
            _xml("_rels/.rels", rels),
            _xml("xl/workbook.xml", workbook),
            _xml("xl/_rels/workbook.xml.rels", workbook_rels),
            _xml("xl/worksheets/sheet1.xml", sheet),
            _xml("docProps/core.xml", core),
        ]
    elif kind == "pptx":
        name = "pptx"
        content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"""
        rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"""
        presentation = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst></p:presentation>"""
        presentation_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>"""
        slide = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld></p:sld>"""
        parts = [
            _xml("[Content_Types].xml", content_types),
            _xml("_rels/.rels", rels),
            _xml("ppt/presentation.xml", presentation),
            _xml("ppt/_rels/presentation.xml.rels", presentation_rels),
            _xml("ppt/slides/slide1.xml", slide),
            _xml("docProps/core.xml", core),
        ]
    else:
        raise AppError("不支持这种空白文档。", "invalid")
    import io

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for part, text in parts:
            if "vbaProject" in part or part.endswith(".bin"):
                raise AppError("空白文档不能包含宏。", "invalid")
            package.writestr(part, text.encode("utf-8"))
    blob = buffer.getvalue()
    if b"vbaProject" in blob or b"TargetMode=\"External\"" in blob:
        raise AppError("空白文档不能包含宏或外部链接。", "invalid")
    return name, blob


def table_xlsx(rows: list[list[str]]) -> bytes:
    import io

    sheet_rows = []
    for r_index, row in enumerate(rows, start=1):
        cells = []
        for c_index, value in enumerate(row):
            column = chr(ord("A") + c_index)
            cells.append(f'<c r="{column}{r_index}" t="inlineStr"><is><t>{escape(value)}</t></is></c>')
        sheet_rows.append(f'<row r="{r_index}">{"".join(cells)}</row>')
    sheet = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
        + "".join(sheet_rows)
        + "</sheetData></worksheet>"
    )
    content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"""
    rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"""
    workbook = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"""
    workbook_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as package:
        package.writestr("[Content_Types].xml", content_types)
        package.writestr("_rels/.rels", rels)
        package.writestr("xl/workbook.xml", workbook)
        package.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        package.writestr("xl/worksheets/sheet1.xml", sheet)
    return buffer.getvalue()
