"""Build and load the Windows application icon from the series artwork."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import io
from functools import lru_cache
from pathlib import Path

from gaocaozuo.native_win import user
from gaocaozuo.resources import asset_dir


# Exact frames for 16, 20, 24 and 32 logical pixels at common desktop scales.
ICON_SIZES = (16, 20, 24, 25, 28, 30, 32, 35, 36, 40, 42, 48, 56, 60, 64, 96, 128, 256)
ICON_NAME = "operation-icon.ico"


def artwork_path() -> Path:
    assets = asset_dir()
    source = assets / "operation-icon.png"
    if source.is_file() or len(assets.parents) <= 3:
        return source
    return assets.parents[3] / "Assets" / "AppIcon.png"


def build_ico(source: Path) -> bytes:
    from PIL import Image

    buffer = io.BytesIO()
    with Image.open(source) as image:
        image.convert("RGBA").save(buffer, format="ICO", sizes=[(size, size) for size in ICON_SIZES])
    return buffer.getvalue()


@lru_cache(maxsize=1)
def workbench_icon_bytes() -> bytes:
    packaged = asset_dir() / ICON_NAME
    return packaged.read_bytes() if packaged.is_file() else build_ico(artwork_path())


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
        with Image.open(artwork_path()) as artwork:
            frame = artwork.convert("RGBA").resize((width, height), Image.Resampling.LANCZOS)
            frame.save(png, format="PNG")
    except (OSError, ImportError):
        return None
    resource = png.getvalue()
    create = user("CreateIconFromResourceEx", w.HICON, w.LPVOID, w.DWORD, w.BOOL, w.DWORD, c.c_int, c.c_int, w.UINT)
    return create(c.create_string_buffer(resource), len(resource), True, 0x00030000, width, height, 0)


if __name__ == "__main__":
    import sys

    Path(sys.argv[2]).write_bytes(build_ico(Path(sys.argv[1])))
