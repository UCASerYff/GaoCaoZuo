"""Windows workbench window and file selection."""

from __future__ import annotations

import os
import hashlib
import json
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from gaocaozuo.errors import AppError


def pick_file(kind: str, multiple: bool) -> list[str]:
    if kind not in {"files", "directory"}:
        raise AppError("请选择文件或目录。", "invalid")
    if os.name != "nt":
        raise AppError("此会话没有 Windows 文件选择器。", "unavailable")
    import tkinter as tk
    from tkinter import filedialog

    try:
        window = tk.Tk()
        window.withdraw()
        window.attributes("-topmost", True)
        try:
            if kind == "directory":
                result = filedialog.askdirectory(parent=window, title="搞操作 · 选择目录", mustexist=True)
            elif multiple:
                result = filedialog.askopenfilenames(parent=window, title="搞操作 · 选择文件")
            else:
                result = filedialog.askopenfilename(parent=window, title="搞操作 · 选择文件")
        finally:
            window.destroy()
    except tk.TclError as exc:
        raise AppError("无法打开 Windows 文件选择器。", "unavailable") from exc
    return list(result) if isinstance(result, tuple) else ([result] if result else [])


def browser_path() -> Path | None:
    directories = [os.getenv("ProgramFiles(x86)"), os.getenv("ProgramFiles"), os.getenv("LOCALAPPDATA")]
    for relative in ("Microsoft/Edge/Application/msedge.exe", "Google/Chrome/Application/chrome.exe"):
        for directory in directories:
            if directory:
                path = Path(directory) / relative
                if path.is_file():
                    return path
    return None


class WorkbenchWindow:
    def __init__(self, url: str):
        binary = browser_path()
        if not binary:
            raise AppError("需安装 Microsoft Edge 或 Google Chrome 才能打开工作台。", "unavailable")
        self.profile = tempfile.TemporaryDirectory(prefix="GaoCaoZuo-window-")
        try:
            self.process = subprocess.Popen([
                str(binary), f"--app={url}", f"--user-data-dir={self.profile.name}",
                "--no-first-run", "--no-default-browser-check", "--disable-background-mode",
                "--disable-extensions", "--window-size=1160,790", "--disable-sync",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.profile.cleanup()
            raise AppError("Windows 无法打开搞操作工作台。", "unavailable") from exc

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        try:
            self.profile.cleanup()
        except OSError:
            pass

    def _handle(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        match = []
        callback_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        pid_for = user("GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))
        visible = user("IsWindowVisible", w.BOOL, w.HWND)

        @callback_type
        def search(hwnd, _arg):
            pid = w.DWORD()
            pid_for(hwnd, c.byref(pid))
            if pid.value == self.process.pid and visible(hwnd):
                match.append(hwnd)
                return False
            return True

        user("EnumWindows", w.BOOL, callback_type, w.LPARAM)(search, 0)
        return match[0] if match else None

    @contextmanager
    def hidden_for_capture(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        hwnd = self._handle()
        if not hwnd or user("IsIconic", w.BOOL, w.HWND)(hwnd):
            yield
            return
        show = user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)
        visible = user("IsWindowVisible", w.BOOL, w.HWND)
        show(hwnd, 0)
        deadline = time.monotonic() + 0.5
        try:
            while visible(hwnd) and time.monotonic() < deadline:
                time.sleep(0.02)
            if visible(hwnd):
                raise AppError("工作台无法隐藏，未捕获画面。", "rejected")
            yield
        finally:
            if self.process.poll() is None and user("IsWindow", w.BOOL, w.HWND)(hwnd):
                show(hwnd, 8)

    def activate(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        hwnd = self._handle()
        if hwnd is None:
            return False
        if user("IsIconic", w.BOOL, w.HWND)(hwnd):
            user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)(hwnd, 9)
        return bool(user("SetForegroundWindow", w.BOOL, w.HWND)(hwnd))


class WorkbenchInstance:
    """Route Explorer activation to this user's current app process."""

    def __init__(self, directory: Path):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import kernel

        signature = os.path.normcase(str(directory.resolve())) + "|" + str(Path(tempfile.gettempdir()).resolve())
        key = hashlib.sha256(signature.encode()).hexdigest()[:28]
        self.file = Path(tempfile.gettempdir()) / f"GaoCaoZuo-{key}.instance"
        c.set_last_error(0)
        self.handle = kernel("CreateMutexW", w.HANDLE, w.LPVOID, w.BOOL, w.LPCWSTR)(None, False, "Local\\GaoCaoZuo-" + key)
        self.primary = c.get_last_error() != 183
        if not self.handle:
            raise AppError("Windows 未能建立单实例会话。", "unavailable")
        self.close_handle = kernel("CloseHandle", w.BOOL, w.HANDLE)

    def publish(self, server):
        from gaocaozuo.atomic import atomic_replace

        atomic_replace(self.file, json.dumps({"port": server.server_address[1], "token": server.token}).encode())

    def handoff(self, paths, package=None):
        from urllib.request import ProxyHandler, Request, build_opener

        opener = build_opener(ProxyHandler({}))
        deadline = time.monotonic() + 10
        data = json.dumps({"paths": paths or [], "package": package}, ensure_ascii=False).encode()
        while time.monotonic() < deadline:
            try:
                state = json.loads(self.file.read_bytes())
                port = int(state["port"])
                if not 0 < port < 65536 or not isinstance(state["token"], str) or len(state["token"]) != 32:
                    raise ValueError("invalid instance")
                request = Request(f"http://127.0.0.1:{port}/api/activate", data=data,
                                  headers={"X-Gao-Token": state["token"], "Content-Type": "application/json"})
                with opener.open(request, timeout=1) as response:
                    return response.status == 200
            except (OSError, ValueError, KeyError, TypeError):
                time.sleep(0.2)
        return False

    def close(self):
        try:
            if self.primary:
                self.file.unlink(missing_ok=True)
        finally:
            self.close_handle(self.handle)


def show_error(message: str) -> None:
    import ctypes

    ctypes.windll.user32.MessageBoxW(None, message, "搞操作", 0x10)
