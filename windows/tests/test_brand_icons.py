import ctypes as c
import ctypes.wintypes as w
import io
import os

import pytest
from PIL import Image

from gaocaozuo import brand_icons
from gaocaozuo.native_win import bind, user


@pytest.fixture
def packaged_ico(tmp_path, monkeypatch):
    contents = brand_icons.build_ico(brand_icons.artwork_path())
    (tmp_path / brand_icons.ICON_NAME).write_bytes(contents)
    monkeypatch.setattr(brand_icons, "asset_dir", lambda: tmp_path)
    return contents


def test_ico_preserves_artwork_and_all_common_dpi_frames(packaged_ico):
    expected = {16, 20, 24, 25, 28, 30, 32, 35, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256}
    with Image.open(io.BytesIO(packaged_ico)) as icon:
        assert icon.format == "ICO" and icon.ico.sizes() == {(size, size) for size in expected}
        for size in sorted(expected):
            image = icon.ico.getimage((size, size)).convert("RGBA")
            for x, y in ((0, 0), (0, size - 1), (size - 1, 0), (size - 1, size - 1)):
                assert image.getpixel((x, y))[3] < 8
            assert image.getpixel((size // 2, size // 2))[3] == 255


def test_icon_plate_and_calligraphy_at_desktop_and_tray_sizes(packaged_ico):
    with Image.open(io.BytesIO(packaged_ico)) as icon:
        for size in (24, 48, 60, 72, 84, 96):
            image = icon.ico.getimage((size, size)).convert("RGBA")
            solid = image.getchannel("A").point(lambda value: 255 if value >= 128 else 0)
            assert solid.getbbox() == (0, 0, size, size)
            assert .95 <= solid.histogram()[255] / (size * size) <= .98
            assert image.getpixel((size // 2, size // 10)) == (119, 119, 119, 255)

        for size, cutoff, height_range, area_range in (
            (16, 198, (8, 10), (10, 14)),
            (24, 208, (14, 16), (22, 32)),
            (48, 208, (31, 33), (140, 155)),
            (72, 208, (47, 49), (360, 400)),
        ):
            image = icon.ico.getimage((size, size)).convert("RGBA")
            glyph = Image.new("L", image.size)
            glyph.putdata([255 if red >= cutoff and alpha >= 248 else 0 for red, _, _, alpha in image.getdata()])
            left, top, right, bottom = glyph.getbbox()
            assert height_range[0] <= bottom - top <= height_range[1]
            assert area_range[0] <= glyph.histogram()[255] <= area_range[1]
            assert abs(left + right - size) <= 2 and abs(top + bottom - size) <= 2


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 icon metrics and loading")
def test_native_ico_loads_requested_small_and_large_dimensions(packaged_ico):
    class IconInfo(c.Structure):
        _fields_ = [("is_icon", w.BOOL), ("x", w.DWORD), ("y", w.DWORD), ("mask", w.HBITMAP), ("color", w.HBITMAP)]

    class Bitmap(c.Structure):
        _fields_ = [("kind", w.LONG), ("width", w.LONG), ("height", w.LONG), ("stride", w.LONG),
                    ("planes", w.WORD), ("bits_per_pixel", w.WORD), ("bits", w.LPVOID)]

    query = user("GetIconInfo", w.BOOL, w.HICON, c.POINTER(IconInfo))
    bitmap_info = bind("gdi32", "GetObjectW", c.c_int, w.HANDLE, c.c_int, w.LPVOID)
    delete_bitmap = bind("gdi32", "DeleteObject", w.BOOL, w.HANDLE)
    destroy = user("DestroyIcon", w.BOOL, w.HICON)
    for dpi, small, large in ((96, 16, 32), (120, 20, 40), (144, 24, 48), (168, 28, 56), (192, 32, 64)):
        for use_small, size in ((True, small), (False, large)):
            width, height = brand_icons.icon_metrics(dpi, small=use_small)
            assert (width, height) == (size, size)
            icon = brand_icons.load_native_icon(width, height)
            assert icon
            info, bitmap = IconInfo(), Bitmap()
            try:
                assert query(icon, c.byref(info)) and info.is_icon and info.color
                assert bitmap_info(info.color, c.sizeof(bitmap), c.byref(bitmap))
                assert (bitmap.width, bitmap.height) == (size, size)
            finally:
                for handle in (info.color, info.mask):
                    if handle:
                        delete_bitmap(handle)
                destroy(icon)
