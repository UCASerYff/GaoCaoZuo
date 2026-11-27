"""Pin OCR handoff files and query their identity using Windows handles."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import msvcrt
import ntpath
import os

from gaocaozuo.errors import AppError
from gaocaozuo.native_win import kernel


class FileBasicInfo(c.Structure):
    _fields_ = [("creation", c.c_int64), ("access", c.c_int64), ("write", c.c_int64),
                ("change", c.c_int64), ("attributes", w.DWORD)]


class FileStandardInfo(c.Structure):
    _fields_ = [("allocation", c.c_int64), ("size", c.c_int64), ("links", w.DWORD),
                ("delete_pending", c.c_ubyte), ("directory", c.c_ubyte)]


class FileIdInfo(c.Structure):
    _fields_ = [("volume", c.c_uint64), ("identifier", c.c_ubyte * 16)]


class ByHandleFileInformation(c.Structure):
    _fields_ = [("attributes", w.DWORD), ("creation", w.FILETIME), ("access", w.FILETIME),
                ("write", w.FILETIME), ("volume", w.DWORD), ("size_high", w.DWORD),
                ("size_low", w.DWORD), ("links", w.DWORD), ("index_high", w.DWORD), ("index_low", w.DWORD)]


def _open_windows_file(path):
    generic_read, share_read, open_existing = 0x80000000, 0x1, 3
    open_reparse_point, backup_semantics = 0x00200000, 0x02000000
    create = kernel("CreateFileW", w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    # Hold this handle throughout the read to exclude writable and deletion handles.
    handle = create(str(path), generic_read, share_read, None, open_existing,
                    open_reparse_point | backup_semantics, None)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    try:
        fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY | os.O_NOINHERIT)
    except BaseException:
        kernel("CloseHandle", w.BOOL, w.HANDLE)(handle)
        raise
    try:
        return os.fdopen(fd, "rb")
    except BaseException as exc:
        os.close(fd)
        if isinstance(exc, IsADirectoryError):
            raise AppError("交接包目录或附件必须为普通、独立的文件对象。", "unsafe") from exc
        raise


def _file_identity(handle, query):
    identity = FileIdInfo()
    if query(handle, 18, c.byref(identity), c.sizeof(identity)):  # FileIdInfo
        identifier = bytes(identity.identifier)
        if any(identifier):
            return identity.volume, identifier
        raise AppError("交接文件在校验时发生变化。", "changed")
    error = c.get_last_error()
    if error not in (1, 50, 87):  # The filesystem may only supply a legacy file index.
        raise c.WinError(error)
    legacy = ByHandleFileInformation()
    if not kernel("GetFileInformationByHandle", w.BOOL, w.HANDLE, c.POINTER(ByHandleFileInformation))(
            handle, c.byref(legacy)):
        raise c.WinError(c.get_last_error())
    index = (legacy.index_high << 32) | legacy.index_low
    if not index:
        raise AppError("交接文件在校验时发生变化。", "changed")
    return legacy.volume, index


def _dos_name(value):
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return ntpath.normcase(value)


def _windows_file_snapshot(source, path):
    handle = msvcrt.get_osfhandle(source.fileno())
    if kernel("GetFileType", w.DWORD, w.HANDLE)(handle) != 1:  # FILE_TYPE_DISK
        raise AppError("交接包目录或附件必须为普通、独立的文件对象。", "unsafe")
    query = kernel("GetFileInformationByHandleEx", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
    basic, standard = FileBasicInfo(), FileStandardInfo()
    if not query(handle, 0, c.byref(basic), c.sizeof(basic)) or not query(handle, 1, c.byref(standard), c.sizeof(standard)):
        raise c.WinError(c.get_last_error())
    if standard.directory or standard.delete_pending or standard.links != 1 or basic.attributes & 0x400:
        raise AppError("交接包目录或附件必须为普通、独立的文件对象。", "unsafe")
    buffer = c.create_unicode_buffer(32768)
    needed = kernel("GetFinalPathNameByHandleW", w.DWORD, w.HANDLE, w.LPWSTR, w.DWORD, w.DWORD)(
        handle, buffer, len(buffer), 0
    )
    if needed == 0 or needed >= len(buffer) or _dos_name(str(path.absolute())) != _dos_name(buffer.value):
        raise AppError("交接文件位置在校验时发生变化。", "changed")
    # Use the same native clocks and resolution at both ends. Reading can change access time.
    return standard.size, _file_identity(handle, query), basic.creation, basic.write, basic.change, basic.attributes
