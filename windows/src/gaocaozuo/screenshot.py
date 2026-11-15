"""截图只在本次明确确认后采集。历史默认关闭。OCR、翻译和录屏明确不可用。"""

from __future__ import annotations

import hashlib
import uuid
from pathlib import Path

from gaocaozuo.errors import AppError
from gaocaozuo.images import draw_rect, encode_png, stitch_vertical


class ScreenshotSession:
    def __init__(self, directory: Path):
        self.directory = directory
        self.history_enabled = False
        self.images: dict[str, tuple[int, int, bytes]] = {}
        self.backend_calls = 0

    def capture(self, explicit: bool, backend) -> dict:
        if not explicit:
            raise AppError("未明确授权本次捕获，未读取屏幕。", "unauthorized")
        self.backend_calls += 1
        width, height, rgb = backend()
        image_id = uuid.uuid4().hex
        self.images[image_id] = (width, height, rgb)
        saved = None
        if self.history_enabled:
            saved = self._write(image_id, width, height, rgb, self.directory / "ScreenshotHistory")
        return {"id": image_id, "width": width, "height": height, "saved": saved, "historyEnabled": self.history_enabled}

    def annotate(self, image_id: str, rects: list[dict]) -> dict:
        width, height, rgb = self._get(image_id)
        for rect in rects:
            color = tuple(rect.get("color") or (255, 59, 48))
            rgb = draw_rect(width, height, rgb, int(rect["x"]), int(rect["y"]), int(rect["w"]), int(rect["h"]), color)
        new_id = uuid.uuid4().hex
        self.images[new_id] = (width, height, rgb)
        return {"id": new_id, "saved": None}

    def stitch(self, image_ids: list[str], overlap: int) -> dict:
        images = [self._get(image_id) for image_id in image_ids]
        width, height, rgb = stitch_vertical(images, overlap)
        new_id = uuid.uuid4().hex
        self.images[new_id] = (width, height, rgb)
        return {"id": new_id, "width": width, "height": height, "scrollInjected": False}

    def save(self, image_id: str, directory: Path) -> str:
        width, height, rgb = self._get(image_id)
        return self._write(image_id, width, height, rgb, directory)

    def pin(self, image_id: str) -> str:
        return self.save(image_id, self.directory / "ScreenshotPins")

    def pins(self) -> list[str]:
        folder = self.directory / "ScreenshotPins"
        if not folder.exists():
            return []
        return sorted(path.name for path in folder.glob("*.png"))

    def ocr(self) -> None:
        raise AppError("Windows 版没有接入系统 OCR，不会把空白结果当成识别成功。", "unavailable")

    def translate(self) -> None:
        raise AppError("Windows 版没有 macOS 本机翻译，也不会联网翻译。", "unavailable")

    def record(self) -> None:
        raise AppError("Windows 版不包含录屏和录音。", "unavailable")

    def _get(self, image_id: str) -> tuple[int, int, bytes]:
        if image_id not in self.images:
            raise AppError("这次捕获已不在会话中。历史未启用时不会从磁盘读回。", "missing")
        return self.images[image_id]

    def _write(self, image_id: str, width: int, height: int, rgb: bytes, directory: Path) -> str:
        directory.mkdir(parents=True, exist_ok=True)
        blob = encode_png(width, height, rgb)
        digest = hashlib.sha256(blob).hexdigest()
        path = directory / f"{digest}.png"
        if not path.exists():
            path.write_bytes(blob)
        return str(path)
