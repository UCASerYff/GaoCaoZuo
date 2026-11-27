"""Confine OCR returns to existing, pinned directories in the Windows user profile."""

from __future__ import annotations

import os
from contextlib import ExitStack, contextmanager
from pathlib import Path

from gaocaozuo.errors import AppError

RETURN_SOURCES = frozenset({"com.gaoseries.GaoWenJian", "com.academic-achievement.manager"})


def default_return_root():
    local = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and local:
        return Path(local) / "GaoSeries" / "GaoAction" / "OcrReturns-v1"
    return None


@contextmanager
def pinned_directory(path, *, exact_name=False, rename=False, writable_parent=False):
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.native_win import kernel
    from gaocaozuo.ocr_provider_win import FileBasicInfo, _dos_name

    # No checked directory can be replaced. Only the destination parent needs
    # write sharing for NTFS's rename. Its separately pinned ticket keeps it nonempty.
    access = 0x80000000 | (0x10000 if rename else 0)
    sharing = 1 | (2 if writable_parent else 0)
    create = kernel("CreateFileW", w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    handle = create(str(path), access, sharing, None, 3, 0x00200000 | 0x02000000, None)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    try:
        basic = FileBasicInfo()
        query = kernel("GetFileInformationByHandleEx", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
        if not query(handle, 0, c.byref(basic), c.sizeof(basic)):
            raise c.WinError(c.get_last_error())
        if basic.attributes & 0x410 != 0x10:  # Plain directory, without FILE_ATTRIBUTE_REPARSE_POINT.
            raise AppError("交接包目录或附件必须为普通、独立的文件对象。", "unsafe")
        final = c.create_unicode_buffer(32768)
        read_name = kernel("GetFinalPathNameByHandleW", w.DWORD, w.HANDLE, w.LPWSTR, w.DWORD, w.DWORD)
        actual = read_name(handle, final, len(final), 0)
        if not actual or actual >= len(final) or _dos_name(final.value) != _dos_name(str(path)):
            raise AppError("交接文件位置在校验时发生变化。", "changed")
        if exact_name and Path(final.value).name != path.name:
            raise AppError("交接请求编号无效。", "invalid")
        yield handle
    finally:
        kernel("CloseHandle", w.BOOL, w.HANDLE)(handle)


@contextmanager
def pinned_path(path, *, exact_name=False, writable_parent=False):
    if (os.name != "nt" or path is None or not path.is_absolute() or len(path.drive) != 2
            or path.drive[1] != ":" or ".." in path.parts):
        raise AppError("交接附件路径无效。", "unsafe")
    if exact_name:
        from ctypes import wintypes as w

        from gaocaozuo.native_win import kernel

        if kernel("GetDriveTypeW", w.UINT, w.LPCWSTR)(path.anchor) != 3:  # DRIVE_FIXED
            raise AppError("交接附件路径无效。", "unsafe")
    with ExitStack() as held:
        for parent in reversed(path.parents):
            held.enter_context(pinned_directory(parent))
        held.enter_context(pinned_directory(path, exact_name=exact_name, writable_parent=writable_parent))
        yield path


def rename_directory(handle, destination):
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.native_win import kernel

    name = str(destination).encode("utf-16-le")

    class RenameInfo(c.Structure):
        _fields_ = [("flags", w.DWORD), ("root", w.HANDLE), ("name_bytes", w.DWORD),
                    ("name", c.c_ubyte * (len(name) + 2))]

    info = RenameInfo()
    info.name_bytes = len(name)
    info.name[:len(name)] = name
    # FILE_RENAME_INFO flags stay zero. Windows fails if the destination exists.
    set_info = kernel("SetFileInformationByHandle", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
    if not set_info(handle, 3, c.byref(info), c.sizeof(info)):
        raise c.WinError(c.get_last_error())
