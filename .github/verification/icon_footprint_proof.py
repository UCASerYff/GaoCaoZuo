import ctypes as ct
from ctypes import wintypes as wt
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import sys

from PIL import Image, ImageDraw, ImageFont


SMALL = (16, 20, 24, 28, 32)
LARGE = (32, 40, 48, 56, 64)
SIZES = tuple(sorted(set(SMALL + LARGE)))
RT_ICON = 3
RT_GROUP_ICON = 14


class Bitmap(ct.Structure):
    _fields_ = [("type", wt.LONG), ("width", wt.LONG), ("height", wt.LONG), ("row_bytes", wt.LONG),
                ("planes", wt.WORD), ("bits", wt.WORD), ("data", ct.c_void_p)]


class IconInfo(ct.Structure):
    _fields_ = [("is_icon", wt.BOOL), ("hotspot_x", wt.DWORD), ("hotspot_y", wt.DWORD),
                ("mask", wt.HBITMAP), ("color", wt.HBITMAP)]


class BitmapInfo(ct.Structure):
    _fields_ = [("header_size", wt.DWORD), ("width", wt.LONG), ("height", wt.LONG),
                ("planes", wt.WORD), ("bits", wt.WORD), ("compression", wt.DWORD),
                ("image_size", wt.DWORD), ("x_density", wt.LONG), ("y_density", wt.LONG),
                ("used", wt.DWORD), ("important", wt.DWORD), ("color", wt.DWORD)]


def dll_function(library, name, returns, *arguments):
    function = getattr(library, name)
    function.restype = returns
    function.argtypes = arguments
    return function


class Win32:
    def __init__(self):
        kernel = ct.WinDLL("kernel32", use_last_error=True)
        user = ct.WinDLL("user32", use_last_error=True)
        gdi = ct.WinDLL("gdi32", use_last_error=True)
        shell = ct.WinDLL("shell32", use_last_error=True)
        self.resource_name_proc = ct.WINFUNCTYPE(wt.BOOL, wt.HMODULE, ct.c_void_p, ct.c_void_p, wt.LPARAM)
        self.load_module = dll_function(kernel, "LoadLibraryExW", wt.HMODULE, wt.LPCWSTR, wt.HANDLE, wt.DWORD)
        self.free_module = dll_function(kernel, "FreeLibrary", wt.BOOL, wt.HMODULE)
        self.enum_names = dll_function(kernel, "EnumResourceNamesW", wt.BOOL, wt.HMODULE, ct.c_void_p,
                                       self.resource_name_proc, wt.LPARAM)
        self.find_resource = dll_function(kernel, "FindResourceW", wt.HANDLE, wt.HMODULE, ct.c_void_p, ct.c_void_p)
        self.load_resource = dll_function(kernel, "LoadResource", wt.HANDLE, wt.HMODULE, wt.HANDLE)
        self.resource_size = dll_function(kernel, "SizeofResource", wt.DWORD, wt.HMODULE, wt.HANDLE)
        self.lock_resource = dll_function(kernel, "LockResource", ct.c_void_p, wt.HANDLE)
        self.load_image = dll_function(user, "LoadImageW", wt.HANDLE, wt.HINSTANCE, ct.c_void_p, wt.UINT,
                                       ct.c_int, ct.c_int, wt.UINT)
        self.extract = dll_function(shell, "SHDefExtractIconW", ct.c_long, wt.LPCWSTR, ct.c_int, wt.UINT,
                                    ct.POINTER(wt.HICON), ct.POINTER(wt.HICON), wt.UINT)
        self.destroy_icon = dll_function(user, "DestroyIcon", wt.BOOL, wt.HICON)
        self.get_icon_info = dll_function(user, "GetIconInfo", wt.BOOL, wt.HICON, ct.POINTER(IconInfo))
        self.get_bitmap_info = dll_function(gdi, "GetObjectW", ct.c_int, wt.HANDLE, ct.c_int, ct.c_void_p)
        self.make_dc = dll_function(gdi, "CreateCompatibleDC", wt.HDC, wt.HDC)
        self.delete_dc = dll_function(gdi, "DeleteDC", wt.BOOL, wt.HDC)
        self.make_dib = dll_function(gdi, "CreateDIBSection", wt.HBITMAP, wt.HDC, ct.POINTER(BitmapInfo),
                                     wt.UINT, ct.POINTER(ct.c_void_p), wt.HANDLE, wt.DWORD)
        self.select = dll_function(gdi, "SelectObject", wt.HANDLE, wt.HDC, wt.HANDLE)
        self.delete_object = dll_function(gdi, "DeleteObject", wt.BOOL, wt.HANDLE)
        self.draw = dll_function(user, "DrawIconEx", wt.BOOL, wt.HDC, ct.c_int, ct.c_int, wt.HICON,
                                 ct.c_int, ct.c_int, wt.UINT, wt.HBRUSH, wt.UINT)
        self.flush = dll_function(gdi, "GdiFlush", wt.BOOL)

    def groups(self, module):
        names = []

        @self.resource_name_proc
        def gather(_, _type, name, _data):
            names.append(name if name <= 0xffff else ct.wstring_at(name))
            return True

        ct.set_last_error(0)
        if not self.enum_names(module, RT_GROUP_ICON, gather, 0) and ct.get_last_error() not in (1812, 1813, 1814):
            raise ct.WinError(ct.get_last_error())
        return names

    def resource(self, module, name, resource_type):
        reference = self.find_resource(module, resource_name(name), resource_type)
        if not reference:
            raise ct.WinError(ct.get_last_error())
        resource = self.load_resource(module, reference)
        start = self.lock_resource(resource) if resource else None
        size = self.resource_size(module, reference)
        if not start or not size:
            raise OSError(f"Empty Windows icon resource {name}")
        return ct.string_at(start, size)

    def group_members(self, module, name):
        directory = self.resource(module, name, RT_GROUP_ICON)
        if len(directory) < 6:
            raise ValueError(f"Truncated icon group {name}")
        reserved, kind, count = struct.unpack_from("<HHH", directory)
        if reserved != 0 or kind != 1 or not count or len(directory) < 6 + count * 14:
            raise ValueError(f"Invalid RT_GROUP_ICON {name}")
        for item in range(count):
            width, height, colors, unused, planes, bits, declared, icon_id = struct.unpack_from("<4BHHIH", directory, 6 + 14 * item)
            payload = self.resource(module, icon_id, RT_ICON)
            yield (width, height, colors, unused, planes, bits, declared, icon_id), payload

    def group_frames(self, module, name):
        return [{"size": [width or 256, height or 256], "id": icon_id, "planes": planes, "bits": bits,
                 "encoding": "PNG" if payload.startswith(b"\x89PNG\r\n\x1a\n") else "DIB",
                 "bytes": len(payload), "bytes_match_directory": len(payload) == declared,
                 "sha256": hashlib.sha256(payload).hexdigest()}
                for (width, height, _, _, planes, bits, declared, icon_id), payload in self.group_members(module, name)]

    def get_icon(self, icon, want_size):
        if not icon:
            raise OSError("Loader did not return an HICON")
        try:
            dimensions = self.hicon_size(icon)
            if dimensions != (want_size, want_size):
                raise ValueError(f"Requested {want_size} px but got an HICON of {dimensions[0]} × {dimensions[1]} px")
            return self.draw_pixels(icon, *dimensions)
        finally:
            self.destroy_icon(icon)

    def hicon_size(self, icon):
        info = IconInfo()
        if not self.get_icon_info(icon, ct.byref(info)):
            raise ct.WinError(ct.get_last_error())
        try:
            bitmap = Bitmap()
            if not self.get_bitmap_info(info.color or info.mask, ct.sizeof(bitmap), ct.byref(bitmap)):
                raise ct.WinError(ct.get_last_error())
            return bitmap.width, abs(bitmap.height) if info.color else abs(bitmap.height) // 2
        finally:
            if info.color:
                self.delete_object(info.color)
            if info.mask:
                self.delete_object(info.mask)

    def draw_pixels(self, icon, width, height):
        info = BitmapInfo(40, width, -height, 1, 32, 0, 0, 0, 0, 0, 0)
        pixels = ct.c_void_p()
        dc = self.make_dc(None)
        if not dc:
            raise ct.WinError(ct.get_last_error())
        dib = previous = None
        byte_count = width * height * 4
        try:
            dib = self.make_dib(dc, ct.byref(info), 0, ct.byref(pixels), None, 0)
            if not dib:
                raise ct.WinError(ct.get_last_error())
            previous = self.select(dc, dib)
            if not previous or previous == ct.c_void_p(-1).value:
                raise ct.WinError(ct.get_last_error())
            backgrounds = []
            for fill in (0, 255):
                ct.memset(pixels, fill, byte_count)
                if not self.draw(dc, 0, 0, icon, width, height, 0, None, 3 | 0x10):
                    raise ct.WinError(ct.get_last_error())
                self.flush()
                backgrounds.append(ct.string_at(pixels, byte_count))
            black, white = backgrounds
        finally:
            if previous and previous != ct.c_void_p(-1).value:
                self.select(dc, previous)
            if dib:
                self.delete_object(dib)
            self.delete_dc(dc)
        rgba = bytearray()
        for offset in range(0, byte_count, 4):
            alpha = 255 - min(255, max(0, max(white[offset + band] - black[offset + band] for band in range(3))))
            color = (min(255, round(black[offset + band] * 255 / alpha)) if alpha else 0 for band in (2, 1, 0))
            rgba.extend((*color, alpha))
        return Image.frombytes("RGBA", (width, height), bytes(rgba))

    def via_shell(self, path, size):
        icon = wt.HICON()
        result = self.extract(str(path), 0, 0, ct.byref(icon), None, size)
        if result != 0:
            if icon:
                self.destroy_icon(icon)
            raise OSError(f"SHDefExtractIconW HRESULT 0x{result & 0xffffffff:08x}")
        return self.get_icon(icon, size)

    def via_resource(self, module, name, size):
        return self.get_icon(self.load_image(module, resource_name(name), 1, size, size, 0), size)

    def via_ico(self, path, size):
        return self.get_icon(self.load_image(None, resource_name(str(path)), 1, size, size, 0x10), size)


def resource_name(name):
    return name if isinstance(name, int) else ct.cast(ct.c_wchar_p(name), ct.c_void_p)


from PyInstaller.archive.readers import CArchiveReader

ico, installer, gui, cli = [Path(arg).resolve(strict=True) for arg in sys.argv[1:]]
expected = {16, 20, 24, 25, 28, 30, 32, 35, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256}
tested_sizes = (16, 20, 24, 28, 32, 40, 48, 56, 60, 64, 72, 84, 96)
win = Win32()
standalone = ico.read_bytes()
for path in (gui, cli):
    archive = CArchiveReader(str(path))
    [entry] = [key for key in archive.toc if key.replace("\\", "/") == "gaocaozuo_assets/operation-icon.ico"]
    assert archive.extract(entry) == standalone, path
    print(f"{path.name} bundled workbench/tray ICO is byte-identical to the standalone artifact.")
disk_frames = {}
for size in tested_sizes:
    loaded = win.via_ico(ico, size)
    assert win.via_shell(ico, size).tobytes() == loaded.tobytes(), (ico, size)
    disk_frames[size] = hashlib.sha256(loaded.tobytes()).hexdigest()
    alpha = loaded.getchannel("A").point(lambda value: 255 if value >= 128 else 0)
    assert alpha.getbbox() == (0, 0, size, size)
    print(f"Standalone ICO {size}px: {alpha.histogram()[255] / (size * size):.3%} solid plate, pixels {disk_frames[size]}")
for path in (installer, gui, cli):
    module = win.load_module(str(path), None, 0x22)
    assert module, path
    try:
        matching = [
            name for name in win.groups(module)
            if {(item["size"][0], item["size"][1]) for item in win.group_frames(module, name)}
            == {(size, size) for size in expected}
        ]
        assert matching, path
        if path != installer:
            assert 1 in matching, (path, matching)
        chosen = 1 if 1 in matching else matching[0]
        for size, digest in disk_frames.items():
            assert hashlib.sha256(win.via_shell(path, size).tobytes()).hexdigest() == digest, (path, size, "Shell")
            assert hashlib.sha256(win.via_resource(module, chosen, size).tobytes()).hexdigest() == digest, (path, size, "LoadImageW")
        print(f"{path.name} {len(expected)} exact frames and native Shell/LoadImageW pixels match standalone ICO at {tested_sizes}.")
    finally:
        win.free_module(module)
