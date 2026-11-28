"""Build and load the Windows application icon from the series artwork."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import io
from functools import lru_cache
from pathlib import Path

from gaocaozuo.native_win import user
from gaocaozuo.resources import asset_dir


# Include exact 48-logical-pixel desktop frames as well as window and tray sizes.
ICON_SIZES = (16, 20, 24, 25, 28, 30, 32, 35, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256)
ICON_NAME = "operation-icon.ico"
ARTWORK_NAME = "operation-icon.png"


def artwork_path() -> Path:
    assets = asset_dir()
    source = assets / ARTWORK_NAME
    if source.is_file() or len(assets.parents) <= 3:
        return source
    return assets.parents[3] / "Assets" / "AppIcon.png"


def _windows_artwork(source: Path):
    from PIL import Image, ImageDraw

    with Image.open(source) as image:
        original = image.convert("RGBA")
    width, height = original.size
    # The original high-resolution gray-to-white pixels encode the calligraphy coverage.
    # Exclude the inset plate edge before extracting that coverage.
    gray = 119
    margin_x, margin_y = width // 5, height // 5
    center = original.crop((margin_x, margin_y, width - margin_x, height - margin_y))
    glyph = center.convert("L").point(lambda value: max(0, (value - gray) * 255 / (255 - gray)))
    glyph = glyph.crop(glyph.getbbox())
    glyph_height = round(height * 0.70)
    glyph = glyph.resize((round(glyph.width * glyph_height / glyph.height), glyph_height), Image.Resampling.LANCZOS)

    mask = Image.new("L", original.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1),
                                           radius=round(min(width, height) * 0.20), fill=255)
    artwork = Image.new("RGBA", original.size, (gray, gray, gray, 255))
    left, top = (width - glyph.width) // 2, (height - glyph.height) // 2
    artwork.paste((255, 255, 255, 255), (left, top, left + glyph.width, top + glyph.height), glyph)
    artwork.putalpha(mask)
    return artwork


def _ico_bytes(artwork) -> bytes:
    buffer = io.BytesIO()
    artwork.save(buffer, format="ICO", sizes=[(size, size) for size in ICON_SIZES])
    return buffer.getvalue()


def build_ico(source: Path) -> bytes:
    return _ico_bytes(_windows_artwork(source))


@lru_cache(maxsize=1)
def artwork_bytes() -> bytes:
    source = artwork_path()
    if source.name == ARTWORK_NAME:
        return source.read_bytes()
    buffer = io.BytesIO()
    _windows_artwork(source).save(buffer, format="PNG")
    return buffer.getvalue()


@lru_cache(maxsize=1)
def workbench_icon_bytes() -> bytes:
    packaged = asset_dir() / ICON_NAME
    if packaged.is_file():
        return packaged.read_bytes()
    from PIL import Image

    with Image.open(io.BytesIO(artwork_bytes())) as artwork:
        return _ico_bytes(artwork)


def icon_metrics(dpi: int, *, small: bool) -> tuple[int, int]:
    first, default = (49, 16) if small else (11, 32)  # SM_CXSMICON or SM_CXICON
    metrics = user("GetSystemMetricsForDpi", c.c_int, c.c_int, w.UINT)
    fallback = max(1, (default * dpi + 48) // 96)
    return metrics(first, dpi) or fallback, metrics(first + 1, dpi) or fallback


def load_native_icon(width: int, height: int) -> int | None:
    """Load one requested size. The caller owns the returned HICON."""
    packaged = asset_dir() / ICON_NAME
    if packaged.is_file():
        load = user("LoadImageW", w.HANDLE, w.HINSTANCE, w.LPCWSTR, w.UINT, c.c_int, c.c_int, w.UINT)
        if icon := load(None, str(packaged), 1, width, height, 0x10):  # IMAGE_ICON, LR_LOADFROMFILE
            return icon

    try:
        from PIL import Image

        png = io.BytesIO()
        with Image.open(io.BytesIO(artwork_bytes())) as artwork:
            frame = artwork.convert("RGBA").resize((width, height), Image.Resampling.LANCZOS)
            frame.save(png, format="PNG")
    except (OSError, ImportError):
        return None
    resource = png.getvalue()
    create = user("CreateIconFromResourceEx", w.HICON, w.LPVOID, w.DWORD, w.BOOL, w.DWORD, c.c_int, c.c_int, w.UINT)
    return create(c.create_string_buffer(resource), len(resource), True, 0x00030000, width, height, 0)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("ico", type=Path)
    parser.add_argument("--png", type=Path)
    args = parser.parse_args()
    artwork = _windows_artwork(args.source)
    args.ico.write_bytes(_ico_bytes(artwork))
    if args.png is not None:
        artwork.save(args.png, format="PNG")
