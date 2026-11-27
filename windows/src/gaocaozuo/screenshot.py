"""Screenshot work, history and locally processed documents."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import os
import re
import tempfile
import time
import uuid
from collections import OrderedDict
from pathlib import Path

from PIL import Image, ImageChops, ImageColor, ImageDraw, ImageFilter, ImageFont, ImageOps, UnidentifiedImageError

from gaocaozuo import capture_win
from gaocaozuo.atomic import atomic_replace
from gaocaozuo.errors import AppError

try:
    from pillow_heif import register_heif_opener
except ImportError:
    register_heif_opener = None
if register_heif_opener:
    register_heif_opener()

MAX_INPUT_BYTES = 128 * 1024 * 1024
MAX_SESSION_BYTES = 256 * 1024 * 1024
MAX_LONG_FRAMES = 35
MAX_AUTO_FRAMES = 12
MAX_AUTO_FRAME_PIXELS = 8_000_000
MAX_AUTO_OUTPUT_PIXELS = 24_000_000
MAX_AUTO_SECONDS = 8


def read_image(source) -> Image.Image:
    try:
        if isinstance(source, Path) and source.stat().st_size > MAX_INPUT_BYTES:
            raise AppError("图像超过 128 MiB。", "invalid")
        with Image.open(source) as image:
            capture_win.check_bounds((0, 0, image.width, image.height))
            if "A" in image.getbands() or "transparency" in image.info:
                oriented = ImageOps.exif_transpose(image).convert("RGBA")
                rgb = Image.new("RGB", oriented.size, "white")
                rgb.paste(oriented, mask=oriented.getchannel("A"))
                return rgb
            return ImageOps.exif_transpose(image).convert("RGB")
    except (OSError, SyntaxError, ValueError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise AppError("所选文件无法解码为图像。", "invalid") from exc


def encode_image(image: Image.Image, format: str = "PNG") -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format=format, quality=93)
    return buffer.getvalue()


def write_new(path: Path, data: bytes) -> Path:
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".gaocaozuo-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if os.name == "nt":
            os.rename(temporary, path)
        else:
            os.link(temporary, path)
        return path
    except FileExistsError as exc:
        raise AppError(f"文件已存在：{path.name}", "conflict") from exc
    except OSError as exc:
        raise AppError("无法写入所选目录。", "rejected") from exc
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _selection(value):
    if value is None:
        return None
    try:
        x, y, width, height = (value[key] for key in ("x", "y", "width", "height"))
        if not all(type(item) is int for item in (x, y, width, height)):
            raise ValueError
        return x, y, x + width, y + height
    except (KeyError, TypeError, ValueError) as exc:
        raise AppError("截图区域必须使用整数像素坐标。", "invalid") from exc


def _output_name(filename: str) -> bool:
    if not isinstance(filename, str) or not filename or filename.endswith((".", " ")):
        return False
    base = filename.split(".")[0].rstrip(" ").upper()
    return (base not in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
            and not re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", base)
            and not any(ord(symbol) < 32 or symbol in ':<>"|?*/\\' for symbol in filename))


def _pause(delay):
    if type(delay) not in (float, int) or not 0 <= delay <= 60:
        raise AppError("延时必须为 0 至 60 秒。", "invalid")
    if delay:
        time.sleep(delay)


def common_overlap(previous: Image.Image, following: Image.Image) -> int:
    width, height = previous.size
    if following.size != previous.size or min(width, height) < 24:
        raise AppError("连续滚动画面尺寸不同或太小。", "invalid")
    if ImageChops.difference(previous, following).getbbox() is None:
        raise AppError("当前画面与上一帧完全相同。请继续向下滚动。", "unchanged")
    # Match downsampled row signatures, then confirm a series of rows so a repeated header cannot win alone.
    samples = min(width, 40)
    x0, x1 = width // 8, width - width // 8
    crop = (x0, 0, x1, height)
    first, second = (
        image.crop(crop).convert("L").resize((samples, height), Image.Resampling.BOX).tobytes()
        for image in (previous, following)
    )
    a = [first[i:i + samples] for i in range(0, len(first), samples)]
    b = [second[i:i + samples] for i in range(0, len(second), samples)]
    low = max(16, height // 12)
    candidates = []
    for shift in range(2, height - low + 1):
        overlap = height - shift
        rows = range(overlap // 6, overlap - overlap // 6, max(1, overlap // 22))
        pair = [(a[shift + index], b[index]) for index in rows]
        if len({row for _, row in pair}) < 4:
            continue
        equal = sum(left == right for left, right in pair) / len(pair)
        if equal >= 0.84:
            candidates.append((equal, shift))
    candidates.sort(reverse=True)
    if not candidates or any(abs(shift - candidates[0][1]) > 2 and score + .06 >= candidates[0][0] for score, shift in candidates[1:]):
        raise AppError("无法唯一对齐滚动内容。请缩小滚动幅度或填入精确重叠像素。", "alignment")
    return height - candidates[0][1]


def _verified_overlap(previous: Image.Image, following: Image.Image) -> int:
    shared = common_overlap(previous, following)
    width, height = previous.size
    first = previous.crop((0, height - shared, width, height))
    second = following.crop((0, 0, width, shared))
    if ImageChops.difference(first, second).getbbox() is not None:
        raise AppError("自动核验发现接缝处像素不一致。请避开固定标题栏和动画，或手动调整后续拍。", "alignment")
    return shared


def _join(images: list[Image.Image], overlap: int | None) -> Image.Image:
    if not images or len(images) > 35 or len({image.width for image in images}) != 1:
        raise AppError("请选择最多 35 张同宽图像。", "invalid")
    removals = [0]
    for previous, following in zip(images, images[1:]):
        shared = common_overlap(previous, following) if overlap is None else overlap
        if type(shared) is not int or not 0 <= shared < min(previous.height, following.height):
            raise AppError("重叠高度超出图像范围。", "invalid")
        removals.append(shared)
    width = images[0].width
    height = sum(image.height - cut for image, cut in zip(images, removals))
    capture_win.check_bounds((0, 0, width, height))
    result = Image.new("RGB", (width, height))
    y = 0
    for image, cut in zip(images, removals):
        result.paste(image.crop((0, cut, width, image.height)), (0, y))
        y += image.height - cut
    return result


def _annotation(image: Image.Image, commands: list[dict]) -> Image.Image:
    if not isinstance(commands, list) or len(commands) > 500:
        raise AppError("一次可提交最多 500 个标注。", "invalid")
    image = image.copy()
    draw = ImageDraw.Draw(image)
    for command in commands:
        try:
            kind = command.get("type", "rect")
            x0 = int(command.get("x", 0))
            y0 = int(command.get("y", 0))
            x1 = int(command.get("x2", x0 + int(command.get("w", 0))))
            y1 = int(command.get("y2", y0 + int(command.get("h", 0))))
            if not all(-2 * max(image.size) <= value <= 2 * max(image.size) for value in (x0, y0, x1, y1)):
                raise ValueError
            color = command.get("color") or "#ff3b30"
            color = ImageColor.getrgb(color) if isinstance(color, str) else tuple(int(c) for c in color)
            if len(color) != 3 or not all(0 <= channel <= 255 for channel in color):
                raise ValueError
            stroke = min(80, max(1, int(command.get("stroke", 3))))
            box = min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)
            if kind == "rotate":
                degrees = command.get("degrees", 90)
                turns = {90: Image.Transpose.ROTATE_270, -90: Image.Transpose.ROTATE_90, 180: Image.Transpose.ROTATE_180}
                if type(degrees) is not int or degrees not in turns:
                    raise ValueError
                image = image.transpose(turns[degrees])
                draw = ImageDraw.Draw(image)
            elif kind == "crop":
                a, b, c, d = box
                crop = max(0, a), max(0, b), min(image.width, c), min(image.height, d)
                if crop[2] - crop[0] < 2 or crop[3] - crop[1] < 2:
                    raise ValueError
                image = image.crop(crop)
                draw = ImageDraw.Draw(image)
            elif kind in {"rect", "rectangle"}:
                draw.rectangle(box, outline=color, width=stroke)
            elif kind in {"ellipse", "oval"}:
                draw.ellipse(box, outline=color, width=stroke)
            elif kind in {"line", "arrow"}:
                draw.line((x0, y0, x1, y1), fill=color, width=stroke)
                if kind == "arrow" and (x0, y0) != (x1, y1):
                    angle = math.atan2(y1 - y0, x1 - x0)
                    head = min(math.hypot(x1 - x0, y1 - y0) / 2, max(12, 4 * stroke))
                    vertices = [(x1 - head * math.cos(angle + offset), y1 - head * math.sin(angle + offset)) for offset in (-.55, .55)]
                    draw.polygon([(x1, y1), *vertices], fill=color)
            elif kind in {"pen", "freehand"}:
                points = command.get("points") or []
                if not 2 <= len(points) <= 3000:
                    raise ValueError
                draw.line([tuple(point) for point in points], fill=color, width=stroke, joint="curve")
            elif kind == "text":
                value = command.get("text")
                if not isinstance(value, str) or not 1 <= len(value) <= 4000:
                    raise ValueError
                size = min(240, max(8, int(command.get("fontSize", 24))))
                try:
                    font = ImageFont.truetype("msyh.ttc", size)
                except OSError:
                    font = ImageFont.load_default()
                draw.multiline_text((x0, y0), value, fill=color, font=font)
            elif kind == "redact":
                draw.rectangle(box, fill=color)
            elif kind in {"mosaic", "pixelate", "highlight", "blur"}:
                a, b, c, d = box
                box = max(0, a), max(0, b), min(image.width, c), min(image.height, d)
                if box[0] >= box[2] or box[1] >= box[3]:
                    continue
                area = image.crop(box)
                if kind == "highlight":
                    area = Image.blend(area, Image.new("RGB", area.size, color), .35)
                elif kind == "blur":
                    area = area.filter(ImageFilter.GaussianBlur(max(6, stroke * 2)))
                else:
                    area = area.resize((max(1, area.width // 14), max(1, area.height // 14)), Image.Resampling.BOX).resize(area.size, Image.Resampling.NEAREST)
                image.paste(area, box)
            else:
                raise ValueError
        except (AttributeError, KeyError, OSError, TypeError, ValueError) as exc:
            raise AppError("标注类型、坐标或样式无效。", "invalid") from exc
    return image


class ScreenshotSession:
    def __init__(self, directory: Path):
        from gaocaozuo.ocr import OcrSession

        self.directory = directory
        self.history_enabled = False
        self.images: OrderedDict[str, Image.Image] = OrderedDict()
        self.editable = {}
        self.backend_calls = 0
        self._long = None
        self._history_error = False
        self._history_settings = directory / "screenshot-settings.json"
        self.recognizer = OcrSession()
        if self._history_settings.is_file():
            try:
                settings = json.loads(self._history_settings.read_text(encoding="utf-8"))
                if settings.get("schema") != 1 or type(settings.get("historyEnabled")) is not bool:
                    raise ValueError
                self.history_enabled = settings["historyEnabled"]
            except (AttributeError, OSError, ValueError):
                self._history_error = True

    def capture(self, explicit: bool, backend=None, *, mode="region", bounds=None, window_id=None, delay=0) -> dict:
        if explicit is not True:
            raise AppError("未明确授权本次捕获，未读取屏幕。", "unauthorized")
        _pause(delay)
        self.backend_calls += 1
        if backend is None:
            if mode == "color":
                return capture_win.sample_color()
            image = capture_win.capture(mode, bounds=_selection(bounds), hwnd=window_id)
        else:
            if not callable(backend):
                raise AppError("截图来源无效。", "invalid")
            width, height, rgb = backend()
            capture_win.check_bounds((0, 0, width, height))
            image = Image.frombytes("RGB", (width, height), rgb)
        return self._add(image, keep_history=True)

    def open(self, path: Path) -> dict:
        if path.suffix.lower() == ".gaowinannotation":
            try:
                if path.stat().st_size > MAX_INPUT_BYTES:
                    raise ValueError
                record = json.loads(path.read_text(encoding="utf-8"))
                if record.get("schemaVersion") != 1:
                    raise ValueError
                base = read_image(io.BytesIO(base64.b64decode(record["image"], validate=True)))
                commands = record["commands"]
                result = self._add(_annotation(base, commands))
                self.editable[result["id"]] = (base, commands)
                return result
            except (AttributeError, KeyError, OSError, TypeError, ValueError) as exc:
                raise AppError("可编辑标注稿格式无效或版本不受支持。", "invalid") from exc
        return self._add(read_image(path))

    def preview(self, image_id: str) -> bytes:
        return encode_image(self._get(image_id))

    def annotate(self, image_id: str, rects: list[dict], commands=None) -> dict:
        original, previous = self.editable.get(image_id, (self._get(image_id), []))
        commands = commands if commands is not None else rects
        if not isinstance(commands, list):
            raise AppError("标注指令须为列表。", "invalid")
        instructions = previous + commands
        result = self._add(_annotation(original, instructions))
        self.editable[result["id"]] = (original, instructions)
        return result

    def stitch(self, image_ids: list[str], overlap=None) -> dict:
        return {**self._add(_join([self._get(image_id) for image_id in image_ids], overlap)), "scrollInjected": False}

    def save(self, image_id: str, directory: Path, filename: str | None = None) -> str:
        image = self._get(image_id)
        if not filename:
            return self._digest_save(image, Path(directory))
        if not _output_name(filename):
            raise AppError("文件名包含目录或 Windows 保留字符。", "invalid")
        path = Path(directory) / filename
        suffix = path.suffix.lower()
        if suffix == ".gaowinannotation":
            base, commands = self.editable.get(image_id, (image, []))
            data = json.dumps({"schemaVersion": 1, "image": base64.b64encode(encode_image(base)).decode("ascii"), "commands": commands}, ensure_ascii=False).encode("utf-8")
            if len(data) > MAX_INPUT_BYTES:
                raise AppError("可编辑标注稿超过 128 MiB。", "invalid")
        else:
            output = {".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".tiff": "TIFF", ".tif": "TIFF", ".webp": "WEBP"}.get(suffix)
            if output is None:
                raise AppError("请选择 PNG、JPEG、TIFF、WebP 或 .gaowinannotation。", "invalid")
            data = encode_image(image, output)
        return str(write_new(path, data))

    def pin(self, image_id: str, persistent=True) -> str | None:
        image = self._get(image_id)
        capture_win.show_pin(image)
        return self._digest_save(image, self.directory / "ScreenshotPins") if persistent else None

    def pins(self) -> list[str]:
        return sorted(path.name for path in (self.directory / "ScreenshotPins").glob("*.png"))

    def restore_pins(self, names=None) -> dict:
        selected = self.pins() if names is None else names
        if not isinstance(selected, list) or len(selected) > 24 or not all(isinstance(name, str) for name in selected):
            raise AppError("一次最多恢复 24 张持久贴图。", "invalid")
        opened, failures = [], []
        for name in selected:
            try:
                image = self.history_open(name, pin=True)
                self.pin(image["id"], persistent=False)
                opened.append(name)
            except AppError as exc:
                failures.append({"name": name, "error": exc.message})
        return {"opened": opened, "failures": failures}

    def history(self, enabled=None) -> dict:
        if enabled is not None:
            if type(enabled) is not bool:
                raise AppError("历史开关须为布尔值。", "invalid")
            if self._history_error:
                raise AppError("历史设置无法读取或版本较新，原设置受到保护。", "rejected")
            new = json.dumps({"schema": 1, "historyEnabled": enabled}).encode("utf-8")
            try:
                atomic_replace(self._history_settings, new)
            except OSError as exc:
                raise AppError("历史设置保存失败。", "rejected") from exc
            self.history_enabled = enabled
        items = sorted((self.directory / "ScreenshotHistory").glob("*.png"), key=lambda path: path.name)
        return {"enabled": self.history_enabled, "items": [{"name": path.name} for path in items], "pins": self.pins(), "recordingAvailable": True}

    def history_open(self, name: str, pin=False) -> dict:
        if not _output_name(name) or not name.casefold().endswith(".png"):
            raise AppError("截图历史文件名无效。", "invalid")
        folder = self.directory / ("ScreenshotPins" if pin else "ScreenshotHistory")
        path = folder / name
        try:
            if getattr(path.lstat(), "st_file_attributes", 0) & 0x400 or path.is_symlink():
                raise AppError("截图历史只能打开本地普通图像。", "unsafe")
        except OSError as exc:
            raise AppError("找不到所选截图历史。", "missing") from exc
        return self.open(path)

    def long_capture(self, command: str, explicit: bool, delay=None, bounds=None, overlap=None) -> dict:
        if explicit is not True:
            raise AppError("未明确授权本次长截图。", "unauthorized")
        if command == "start":
            if self._long:
                raise AppError("请先完成或取消当前长截图。", "conflict")
            region = _selection(bounds) or capture_win.choose_region()
            window = capture_win.window_at_center(region)
            identity = capture_win.window_identity(window)
            if not identity:
                raise AppError("所选区域没有可跟踪的目标窗口。", "missing")
            if not capture_win.region_has_target(region, window):
                raise AppError("长截图区域须完全位于同一窗口内，且没有被其他窗口遮挡。", "rejected")
            frame = capture_win.window_frame(window)
            image = capture_win.capture("region", region)
            if (capture_win.window_identity(window) != identity or capture_win.window_frame(window) != frame
                    or not capture_win.region_has_target(region, window)):
                raise AppError("截图时目标窗口已改变，请重新选择范围。", "rejected")
            self._long = {"region": region, "window": window, "identity": identity, "frame": frame,
                          "last": image, "image": image, "frames": 1}
        elif command == "cancel":
            self._long = None
            return {"active": False}
        elif command in {"append", "auto", "finish"}:
            if self._long is None:
                raise AppError("先开始一个长截图会话。", "missing")
            if command == "finish":
                if self._long["frames"] < 2:
                    raise AppError("请至少添加第二帧后再生成长截图。", "invalid")
                result = self._add(self._long["image"], keep_history=True)
                self._long = None
                return {**result, "active": False}
            state = self._long
            if state["frames"] >= MAX_LONG_FRAMES:
                raise AppError("本次长截图已达到 35 帧。", "invalid")
            if command == "auto":
                return self._auto_long_capture(state, 3 if delay is None else delay)
            _pause(3 if delay is None else delay)
            current = self._read_long_frame(state, lambda: self._verify_long_window(state))
            self._append_long_frame(state, current, common_overlap(state["last"], current) if overlap is None else overlap)
        else:
            raise AppError("未知的长截图操作。", "invalid")
        return self._long_status(self._long)

    @staticmethod
    def _long_status(state: dict) -> dict:
        return {"active": True, "frames": state["frames"], "width": state["image"].width, "height": state["image"].height}

    @staticmethod
    def _verify_long_window(state: dict) -> None:
        window = state["window"]
        if (capture_win.foreground_window() != window or capture_win.window_identity(window) != state["identity"]
                or capture_win.window_frame(window) != state["frame"] or not capture_win.region_has_target(state["region"], window)):
            raise AppError("目标窗口已改变。请切回原窗口、保持原位置并重试。", "rejected")

    @staticmethod
    def _read_long_frame(state: dict, verify) -> Image.Image:
        verify()
        image = capture_win.capture("region", state["region"])
        verify()
        if image.size != state["last"].size:
            raise AppError("窗口画面大小已变更，请重新选择区域。", "targetChanged")
        return image

    @staticmethod
    def _append_long_frame(state: dict, image: Image.Image, shared: int) -> None:
        state["image"] = _join([state["image"], image], shared)
        state["last"] = image
        state["frames"] += 1

    def _auto_long_capture(self, state: dict, delay) -> dict:
        if type(delay) not in (int, float) or not 0 <= delay <= 10:
            raise AppError("自动滚动等待时间须为 0 至 10 秒。", "invalid")
        original_count = state["frames"]
        reason = "已达本轮自动滚动上限，可以再次启动或生成长截图。"
        stop = "limit"
        region, identity, frame = (state[key] for key in ("region", "identity", "frame"))
        width, height = state["last"].size
        try:
            if frame is None:
                raise AppError("无法核验目标窗口的位置，请手动续拍。", "scrollUnavailable")
            if width < 24 or height < 96 or width * height > MAX_AUTO_FRAME_PIXELS:
                raise AppError("自动滚动需要 24 像素宽、96 像素高以上且不超过 800 万像素的选区。", "sizeLimit")
            _pause(delay)
            deadline = time.monotonic() + MAX_AUTO_SECONDS
            anchor = capture_win.verify_scroll_anchor(region, identity, frame)

            def verify():
                if time.monotonic() >= deadline:
                    raise AppError("本轮自动滚动时间已到，可以再次启动或手动续拍。", "limit")
                return capture_win.verify_scroll_anchor(region, identity, frame, anchor)

            initial = self._read_long_frame(state, verify)
            if ImageChops.difference(state["last"], initial).getbbox() is not None:
                raise AppError("当前画面与上一帧不同，请先手动添加当前画面。", "initialChanged")
            del initial
            for _ in range(min(MAX_AUTO_FRAMES, MAX_LONG_FRAMES - original_count)):
                if state["image"].width * (state["image"].height + height) > MAX_AUTO_OUTPUT_PIXELS:
                    raise AppError("已接近自动拼接画面大小上限，可以生成长截图。", "limit")
                verify()
                capture_win.scroll_down(region, identity, frame, anchor)
                _pause(.45)
                current = self._read_long_frame(state, verify)
                try:
                    shared = _verified_overlap(state["last"], current)
                except AppError as exc:
                    if exc.code == "unchanged":
                        raise AppError("画面未移动，可能已到边界或目标未处理滚动。", "unchanged") from exc
                    raise
                verify()
                self._append_long_frame(state, current, shared)
        except AppError as exc:
            stop, reason = exc.code, exc.message
        return {**self._long_status(state), "automatic": {"added": state["frames"] - original_count, "stop": stop, "reason": reason}}

    def ocr(self, explicit=False, *, image_id=None, paths=None, clipboard_data=None, languages=None) -> dict:
        if explicit is not True:
            raise AppError("请先明确确认本次 OCR 输入。", "unavailable")
        if sum(item is not None for item in (image_id, paths, clipboard_data)) != 1:
            raise AppError("请选择截图、剪贴板图像或本机文件中的一项。", "invalid")
        if image_id is not None:
            return self.recognizer.recognize_image("截图.png", self._get(image_id), languages)
        if clipboard_data is not None:
            if len(clipboard_data) > MAX_INPUT_BYTES:
                raise AppError("剪贴板图像超过 128 MiB。", "invalid")
            return self.recognizer.recognize_image("剪贴板.png", read_image(io.BytesIO(clipboard_data)), languages)
        return self.recognizer.recognize_paths(paths, languages)

    def ocr_languages(self) -> dict:
        return self.recognizer.languages()

    def ocr_export(self, document_id, directory, format) -> dict:
        return self.recognizer.export(document_id, Path(directory), format)

    def translate(self) -> None:
        raise AppError("本机没有已接入的离线翻译服务。", "unavailable")

    def record(self) -> None:
        raise AppError("请在录制页使用 Windows 浏览器提供的录制权限和来源选择。", "unavailable")

    def _add(self, image: Image.Image, keep_history=False) -> dict:
        width, height = image.size
        image_id = uuid.uuid4().hex
        self.images[image_id] = image
        while len(self.images) > 20 or sum(item.width * item.height * 3 for item in self.images.values()) > MAX_SESSION_BYTES:
            evicted, _image = self.images.popitem(last=False)
            self.editable.pop(evicted, None)
        saved = self._digest_save(image, self.directory / "ScreenshotHistory") if keep_history and self.history_enabled else None
        return {"id": image_id, "width": width, "height": height, "saved": saved, "historyEnabled": self.history_enabled}

    def _get(self, image_id: str) -> Image.Image:
        if image_id not in self.images:
            raise AppError("这张图像已不在当前工作区。", "missing")
        self.images.move_to_end(image_id)
        return self.images[image_id]

    def _digest_save(self, image: Image.Image, directory: Path) -> str:
        blob = encode_image(image)
        digest = hashlib.sha256(blob).hexdigest()
        path = directory / f"{digest}.png"
        if path.is_file() and not path.is_symlink():
            file = path.stat()
            if not getattr(file, "st_file_attributes", 0) & 0x400 and file.st_size == len(blob) and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
                return str(path)
        return str(write_new(path, blob))
