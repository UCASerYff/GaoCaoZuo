"""Windows workbench window and file selection."""

from __future__ import annotations

import os
import hashlib
import json
import subprocess
import tempfile
import time
from contextlib import ExitStack, contextmanager
from pathlib import Path

from gaocaozuo.errors import AppError
from gaocaozuo.localization import native_text


def pick_file(kind: str, multiple: bool, *, filetypes=()) -> list[str]:
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
                result = filedialog.askdirectory(parent=window, title="搞操作 · " + native_text("选择目录"), mustexist=True)
            elif multiple:
                result = filedialog.askopenfilenames(parent=window, title="搞操作 · " + native_text("选择文件"), filetypes=filetypes)
            else:
                result = filedialog.askopenfilename(parent=window, title="搞操作 · " + native_text("选择文件"), filetypes=filetypes)
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


def _start_on_workbench_desktop(arguments):
    import ctypes as c
    from ctypes import wintypes as w
    from gaocaozuo.native_win import kernel, user

    class StartupInfo(c.Structure):
        _fields_ = [("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                    *[(name, w.DWORD) for name in ("x", "y", "width", "height", "columns", "rows", "fill", "flags")],
                    ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_data", w.LPVOID),
                    ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]

    class ProcessInfo(c.Structure):
        _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]

    query = user("GetUserObjectInformationW", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
    station = user("GetProcessWindowStation", w.HANDLE)()
    thread = kernel("GetCurrentThreadId", w.DWORD)()
    desktop = user("GetThreadDesktop", w.HANDLE, w.DWORD)(thread)
    names = []
    for handle in (station, desktop):
        name, length = c.create_unicode_buffer(256), w.DWORD()
        if not handle or not query(handle, 2, name, c.sizeof(name), c.byref(length)):
            raise c.WinError(c.get_last_error())
        names.append(name.value)
    # With no inherited desktop handle, a child can connect to the default desktop.
    startup = StartupInfo(size=c.sizeof(StartupInfo), desktop="\\".join(names))
    command = c.create_unicode_buffer(subprocess.list2cmdline(arguments))
    info = ProcessInfo()
    create = kernel("CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL,
                    w.DWORD, w.LPVOID, w.LPCWSTR, c.POINTER(StartupInfo), c.POINTER(ProcessInfo))
    if not create(arguments[0], command, None, None, False, 0x4, None, None, c.byref(startup), c.byref(info)):
        raise c.WinError(c.get_last_error())
    return info.process, info.thread, info.pid


class _BrowserProcess:
    """Own the workbench's Chromium process and descendants via one Windows job."""

    def __init__(self, arguments):
        import _winapi
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import kernel

        class BasicLimits(c.Structure):
            _fields_ = [("per_process_time", c.c_int64), ("per_job_time", c.c_int64), ("flags", w.DWORD),
                        ("minimum_working_set", c.c_size_t), ("maximum_working_set", c.c_size_t),
                        ("process_limit", w.DWORD), ("affinity", c.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]

        class ExtendedLimits(c.Structure):
            _fields_ = [("basic", BasicLimits), ("io_counters", c.c_uint64 * 6), ("process_memory", c.c_size_t),
                        ("job_memory", c.c_size_t), ("peak_process_memory", c.c_size_t), ("peak_job_memory", c.c_size_t)]

        job = kernel("CreateJobObjectW", w.HANDLE, w.LPVOID, w.LPCWSTR)(None, None)
        if not job:
            raise c.WinError(c.get_last_error())
        process = thread = None
        try:
            limits = ExtendedLimits()
            limits.basic.flags = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            set_limits = kernel("SetInformationJobObject", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
            if not set_limits(job, 9, c.byref(limits), c.sizeof(limits)):
                raise c.WinError(c.get_last_error())
            # Start suspended so Chromium cannot spawn untracked descendants.
            process, thread, self.pid = _start_on_workbench_desktop(arguments)
            assign = kernel("AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE)
            resume = kernel("ResumeThread", w.DWORD, w.HANDLE)
            if not assign(job, process) or resume(thread) == 0xFFFFFFFF:
                raise c.WinError(c.get_last_error())
        except BaseException:
            if process is not None:
                try:
                    _winapi.TerminateProcess(process, 1)
                except OSError:
                    pass
                _winapi.CloseHandle(process)
            _winapi.CloseHandle(job)
            raise
        finally:
            if thread is not None:
                _winapi.CloseHandle(thread)
        self._api, self._job, self._process = _winapi, job, process

    def poll(self):
        if self._api.WaitForSingleObject(self._process, 0) == self._api.WAIT_TIMEOUT:
            return None
        return self._api.GetExitCodeProcess(self._process)

    def process_ids(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import kernel

        query = kernel("QueryInformationJobObject", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
        capacity = 32
        while True:
            class ProcessIDList(c.Structure):
                _fields_ = [("assigned", w.DWORD), ("listed", w.DWORD), ("pids", c.c_size_t * capacity)]

            members = ProcessIDList()
            if query(self._job, 3, c.byref(members), c.sizeof(members), None):  # JobObjectBasicProcessIdList
                if members.listed == members.assigned:
                    return set(members.pids[:members.listed])
            elif c.get_last_error() != 234:  # ERROR_MORE_DATA
                raise c.WinError(c.get_last_error())
            capacity = max(members.assigned, 2 * capacity)

    @contextmanager
    def member(self, pid):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import kernel

        open_process = kernel("OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
        process = open_process(0x00101000, False, pid)  # SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
        try:
            in_job = w.BOOL()
            check = kernel("IsProcessInJob", w.BOOL, w.HANDLE, w.HANDLE, c.POINTER(w.BOOL))
            yield process if process and check(process, self._job, c.byref(in_job)) and in_job.value else None
        finally:
            if process:
                self._api.CloseHandle(process)

    def is_running(self):
        if self.poll() is None:
            return True
        # Edge can hand off the window to a Job member and exit as a launcher.
        for pid in self.process_ids() - {self.pid}:
            with self.member(pid) as process:
                if process and self._api.WaitForSingleObject(process, 0) == self._api.WAIT_TIMEOUT:
                    return True
        return False

    def wait(self, seconds):
        self._api.WaitForSingleObject(self._process, int(seconds * 1000))

    def close(self):
        with ExitStack() as held:
            try:
                members = [process for pid in self.process_ids() - {self.pid}
                           if (process := held.enter_context(self.member(pid)))]
            except OSError:
                members = []
            self._api.CloseHandle(self._job)
            try:
                deadline = time.monotonic() + 5
                for process in (self._process, *members):
                    remaining = max(0, int((deadline - time.monotonic()) * 1000))
                    self._api.WaitForSingleObject(process, remaining)
            finally:
                self._api.CloseHandle(self._process)


class WorkbenchWindow:
    def __init__(self, url: str):
        from gaocaozuo.brand_shell_win import WorkbenchBrand

        binary = browser_path()
        if not binary:
            raise AppError("需安装 Microsoft Edge 或 Google Chrome 才能打开工作台。", "unavailable")
        self.profile = tempfile.TemporaryDirectory(prefix="GaoCaoZuo-window-")
        self._hwnd = None
        self._seen_window = False
        self._missing_since = None
        self._brand = WorkbenchBrand()
        try:
            self.process = _BrowserProcess([
                str(binary), f"--app={url}", f"--user-data-dir={self.profile.name}",
                "--no-first-run", "--no-default-browser-check", "--disable-background-mode",
                "--disable-extensions", "--window-size=1160,790", "--disable-sync", "--disable-breakpad",
            ])
        except OSError as exc:
            self.profile.cleanup()
            raise AppError("Windows 无法打开搞操作工作台。", "unavailable") from exc

    def close(self):
        import _winapi
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        try:
            if window := self._window():
                hwnd, pid = window
                with self.process.member(pid) as process:
                    if process:
                        self._brand.unbind(hwnd, pid)
                        user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, 0x0010, 0, 0)  # WM_CLOSE
                        _winapi.WaitForSingleObject(process, 2000)
        finally:
            try:
                self.process.close()
            finally:
                self._brand.close()
                try:
                    self.profile.cleanup()
                except OSError:
                    pass

    def is_running(self):
        if self._window():
            self._missing_since = None
            return True
        if not self.process.is_running():
            return False
        if not self._seen_window:
            return True
        # An already opened window has closed. Allow a short grace for replacement
        # or normal browser teardown, then retire any remaining background helpers.
        now = time.monotonic()
        if self._missing_since is None:
            self._missing_since = now
        return now - self._missing_since < 0.5

    def window_pid(self):
        if window := self._window():
            hwnd, pid = window
            self._brand.update(hwnd, pid)
            return pid
        return None

    def refresh_shell_brand(self):
        self._brand.schedule_recheck()

    def _handle(self):
        window = self._window()
        return window[0] if window else None

    def _window(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import kernel, user

        result = None
        callback_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        pid_for = user("GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))
        visible = user("IsWindowVisible", w.BOOL, w.HWND)
        name = user("GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
        owner = user("GetWindow", w.HWND, w.HWND, w.UINT)
        members = self.process.process_ids()
        if not members:
            self._hwnd = None
            return None

        def match(hwnd):
            pid, kind = w.DWORD(), c.create_unicode_buffer(64)
            if (not pid_for(hwnd, c.byref(pid)) or pid.value not in members or owner(hwnd, 4) or
                    not name(hwnd, kind, len(kind)) or kind.value != "Chrome_WidgetWin_1"):
                return None
            with self.process.member(pid.value) as process:
                current = w.DWORD()
                if process and pid_for(hwnd, c.byref(current)) and current.value == pid.value:
                    return hwnd, pid.value
            return None

        if self._hwnd and (result := match(self._hwnd)):
            return result

        @callback_type
        def search(hwnd, _arg):
            nonlocal result
            if visible(hwnd) and (result := match(hwnd)):
                return False
            return True

        thread = kernel("GetCurrentThreadId", w.DWORD)()
        desktop = user("GetThreadDesktop", w.HANDLE, w.DWORD)(thread)
        user("EnumDesktopWindows", w.BOOL, w.HANDLE, callback_type, w.LPARAM)(desktop, search, 0)
        self._hwnd = result[0] if result else None
        self._seen_window |= result is not None
        return result

    def hide(self) -> bool:
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        hwnd = self._handle()
        return bool(hwnd and user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)(hwnd, 0))

    @contextmanager
    def hidden_for_capture(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        hwnd = self._handle()
        visible = user("IsWindowVisible", w.BOOL, w.HWND)
        if not hwnd or not visible(hwnd) or user("IsIconic", w.BOOL, w.HWND)(hwnd):
            yield
            return
        show = user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)
        show(hwnd, 0)
        deadline = time.monotonic() + 0.5
        try:
            while visible(hwnd) and time.monotonic() < deadline:
                time.sleep(0.02)
            if visible(hwnd):
                raise AppError("工作台无法隐藏，未捕获画面。", "rejected")
            yield
        finally:
            if self._handle() == hwnd:
                show(hwnd, 8)

    def activate(self):
        import ctypes as c
        from ctypes import wintypes as w
        from gaocaozuo.native_win import user

        hwnd = self._handle()
        if hwnd is None:
            return False
        if not user("IsWindowVisible", w.BOOL, w.HWND)(hwnd) or user("IsIconic", w.BOOL, w.HWND)(hwnd):
            user("ShowWindowAsync", w.BOOL, w.HWND, c.c_int)(hwnd, 9)
        user("SetForegroundWindow", w.BOOL, w.HWND)(hwnd)
        self._brand.schedule_recheck()
        return True


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
