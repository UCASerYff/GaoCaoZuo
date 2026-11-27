"""Store explicitly saved archive passwords in Windows Credential Manager."""

from __future__ import annotations

import ctypes as ct
import hashlib
import os
from ctypes import wintypes as wt

from gaocaozuo.errors import AppError
from gaocaozuo.native_win import bind


class Credential(ct.Structure):
    _fields_ = [
        ("flags", wt.DWORD), ("kind", wt.DWORD), ("target", wt.LPWSTR), ("comment", wt.LPWSTR),
        ("updated", wt.FILETIME), ("size", wt.DWORD), ("secret", ct.POINTER(ct.c_ubyte)), ("persist", wt.DWORD),
        ("attribute_count", wt.DWORD), ("attributes", wt.LPVOID), ("alias", wt.LPWSTR), ("username", wt.LPWSTR),
    ]


class WindowsCredentialVault:
    def __init__(self, directory):
        signature = hashlib.sha256(os.path.normcase(str(directory.resolve())).encode()).hexdigest()[:20]
        self.prefix = "GaoSeries/GaoCaoZuo/Archive/" + signature + "/"

    def put(self, account: str, secret: str) -> None:
        data = secret.encode("utf-8")
        if len(data) > 2560:
            raise AppError("密码超过 Windows 凭据管理器长度限制。", "budget")
        buffer = (ct.c_ubyte * len(data)).from_buffer_copy(data)
        credential = Credential(kind=1, target=self.prefix + account, size=len(data), secret=buffer,
                                persist=2, username="GaoCaoZuo")
        try:
            if not bind("advapi32", "CredWriteW", wt.BOOL, ct.POINTER(Credential), wt.DWORD)(ct.byref(credential), 0):
                raise AppError("压缩包已创建，Windows 未能保存密码。", "credential")
        finally:
            ct.memset(buffer, 0, len(data))

    def get(self, account: str) -> str | None:
        item = ct.POINTER(Credential)()
        if not bind("advapi32", "CredReadW", wt.BOOL, wt.LPCWSTR, wt.DWORD, wt.DWORD,
                    ct.POINTER(ct.POINTER(Credential)))(self.prefix + account, 1, 0, ct.byref(item)):
            if ct.get_last_error() == 1168:
                return None
            raise AppError("无法读取此压缩包单独保存的 Windows 凭据。", "credential")
        try:
            return ct.string_at(item.contents.secret, item.contents.size).decode("utf-8")
        except UnicodeError as exc:
            raise AppError("此压缩包保存的 Windows 凭据格式无效。", "credential") from exc
        finally:
            bind("advapi32", "CredFree", None, wt.LPVOID)(item)
