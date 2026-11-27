"""Exercise the Windows desktop entry in a disposable, never-switched desktop."""

from __future__ import annotations

import argparse
import base64
import ctypes as c
import ctypes.wintypes as w
import hashlib
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import ExitStack, closing, contextmanager, nullcontext
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from gaocaozuo.native_win import kernel, user


DESKTOP_PREFIX = "GaoLifecycleQA-"
BROWSER_TITLE = "搞操作 V1.16"
TRAY_CAPTION = "搞操作 · 通知区域"
NOTIFY_MESSAGE = 0x8001
EXE = getattr(sys, "_base_executable", sys.executable)


class StartupInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                *[(name, w.DWORD) for name in ("x", "y", "width", "height", "columns", "rows", "fill", "flags")],
                ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_data", w.LPVOID),
                ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class ProcessEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("pid", w.DWORD), ("heap", c.c_size_t),
                ("module", w.DWORD), ("threads", w.DWORD), ("parent", w.DWORD), ("priority", w.LONG),
                ("flags", w.DWORD), ("name", w.WCHAR * 260)]


def descendants(pid):
    snapshot = kernel("CreateToolhelp32Snapshot", w.HANDLE, w.DWORD, w.DWORD)(2, 0)
    if snapshot == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    children = {}
    try:
        entry = ProcessEntry(size=c.sizeof(ProcessEntry))
        more = kernel("Process32FirstW", w.BOOL, w.HANDLE, c.POINTER(ProcessEntry))(snapshot, c.byref(entry))
        advance = kernel("Process32NextW", w.BOOL, w.HANDLE, c.POINTER(ProcessEntry))
        while more:
            children.setdefault(entry.parent, []).append(entry.pid)
            more = advance(snapshot, c.byref(entry))
    finally:
        kernel("CloseHandle", w.BOOL, w.HANDLE)(snapshot)
    all_children = set()
    visit = [pid]
    while visit:
        for child in children.get(visit.pop(), ()):
            if child != pid and child not in all_children:
                all_children.add(child)
                visit.append(child)
    return all_children


def watch_process(pid, stack):
    process = kernel("OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)(0x00100000, False, pid)  # SYNCHRONIZE
    if not process:
        raise c.WinError(c.get_last_error())
    stack.callback(kernel("CloseHandle", w.BOOL, w.HANDLE), process)
    wait = kernel("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
    return lambda: wait(process, 0) == 0


def create_desktop_process(executable, arguments, desktop, scratch, flags=0):
    startup = StartupInfo(size=c.sizeof(StartupInfo), desktop=desktop)
    info = ProcessInfo()
    command = c.create_unicode_buffer(arguments)
    env = {**os.environ, "PYTHONUTF8": "1", "TEMP": str(scratch), "TMP": str(scratch)}
    env_text = "\0".join(f"{key}={value}" for key, value in sorted(env.items(), key=lambda item: item[0].casefold())) + "\0\0"
    env_block = c.create_unicode_buffer(env_text)
    create = kernel("CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL,
                    w.DWORD, w.LPVOID, w.LPCWSTR, c.POINTER(StartupInfo), c.POINTER(ProcessInfo))
    if not create(executable, command, None, None, False, flags | 0x08000400,
                  env_block, None, c.byref(startup), c.byref(info)):
        raise c.WinError(c.get_last_error())
    return info


class IsolatedProcess:
    def __init__(self, arguments, desktop, scratch):
        command = subprocess.list2cmdline([str(arg) for arg in arguments])
        info = create_desktop_process(str(arguments[0]), command, desktop, scratch)
        self.handle = info.process
        self.pid = info.pid
        kernel("CloseHandle", w.BOOL, w.HANDLE)(info.thread)

    def wait(self, timeout):
        value = kernel("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)(self.handle, round(timeout * 1000))
        if value == 258:
            raise subprocess.TimeoutExpired(str(self.pid), timeout)
        if value != 0:
            raise c.WinError(c.get_last_error())
        return self.poll()

    def poll(self):
        exit_code = w.DWORD()
        if not kernel("GetExitCodeProcess", w.BOOL, w.HANDLE, w.LPDWORD)(self.handle, c.byref(exit_code)):
            raise c.WinError(c.get_last_error())
        return None if exit_code.value == 259 else exit_code.value

    def terminate(self):
        if self.poll() is None and not kernel("TerminateProcess", w.BOOL, w.HANDLE, w.UINT)(self.handle, 97):
            if self.poll() is None:
                raise c.WinError(c.get_last_error())

    def ensure_stopped(self):
        if self.handle is None:
            return
        if self.poll() is None:
            self.terminate()
            self.wait(8)
        kernel("CloseHandle", w.BOOL, w.HANDLE)(self.handle)
        self.handle = None


def desktop_name(handle):
    get = user("GetUserObjectInformationW", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, w.LPDWORD)
    name, size = c.create_unicode_buffer(128), w.DWORD()
    if not get(handle, 2, name, c.sizeof(name), c.byref(size)):
        raise c.WinError(c.get_last_error())
    return name.value


def current_desktop():
    thread = kernel("GetCurrentThreadId", w.DWORD)()
    return user("GetThreadDesktop", w.HANDLE, w.DWORD)(thread)


def verify_desktop(expected):
    if not expected.startswith(DESKTOP_PREFIX) or desktop_name(current_desktop()) != expected:
        raise RuntimeError("Refusing to run a lifecycle fixture outside its named test desktop.")
    active = user("OpenInputDesktop", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)(0, False, 1)
    if not active:
        raise c.WinError(c.get_last_error())
    try:
        if desktop_name(active) == expected:
            raise RuntimeError("The test desktop must remain detached from input.")
    finally:
        user("CloseDesktop", w.BOOL, w.HANDLE)(active)


@contextmanager
def detached_desktop():
    name = DESKTOP_PREFIX + secrets.token_hex(10)
    previous = current_desktop()
    create = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)
    handle = create(name, None, None, 0, 0x000F01FF, None)
    if not handle:
        raise c.WinError(c.get_last_error())
    select = user("SetThreadDesktop", w.BOOL, w.HANDLE)
    try:
        if not select(handle):
            raise c.WinError(c.get_last_error())
        verify_desktop(name)
        yield name, handle
    finally:
        select(previous)
        user("CloseDesktop", w.BOOL, w.HANDLE)(handle)


def post(hwnd, message, first=0, second=0):
    if not user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, message, first, second):
        raise c.WinError(c.get_last_error())


def find_windows(title):
    matches = []
    procedure = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    read_text = user("GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
    pid_for = user("GetWindowThreadProcessId", w.DWORD, w.HWND, w.LPDWORD)

    @procedure
    def visit(hwnd, _):
        caption = c.create_unicode_buffer(128)
        if read_text(hwnd, caption, len(caption)) and caption.value == title:
            pid = w.DWORD()
            pid_for(hwnd, c.byref(pid))
            matches.append((hwnd, pid.value))
        return True

    user("EnumWindows", w.BOOL, procedure, w.LPARAM)(visit, 0)
    return matches


def until(read, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(.07)
    raise AssertionError(f"Timed out waiting for {description}.")


def http(port, token, endpoint, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    request = Request(f"http://127.0.0.1:{port}/api/{endpoint}", data=body,
                      headers={"X-Gao-Token": token, "Content-Type": "application/json"})
    with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
        return json.load(response)


def wait_port_closed(port):
    def closed():
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.15):
                return False
        except OSError:
            return True

    until(closed, "closure of the isolated loopback port", 8)


def app_child(name, scratch, data_dir, browser, entry_args):
    verify_desktop(name)
    local_data = scratch / "LocalAppData"
    local_data.mkdir(exist_ok=True)
    os.environ["LOCALAPPDATA"] = str(local_data)
    from gaocaozuo import cli, shell_win, tray_win

    native_launch_only = "--test-native-launch" in entry_args
    entry_args = [argument for argument in entry_args if argument != "--test-native-launch"]
    original_start = shell_win._start_on_workbench_desktop

    class ObservedWindow(shell_win.WorkbenchWindow):
        def __init__(self, url):
            super().__init__(url)
            with (scratch / "browser-launchers.jsonl").open("a", encoding="ascii") as evidence:
                evidence.write(json.dumps({"launcherPID": self.process.pid}) + "\n")

    def start_browser(arguments):
        # Only append test-local inspection settings. Desktop selection, Windows
        # process creation and Job assignment all go through the normal launcher.
        assert arguments[0] == str(browser) and arguments[1].startswith("--app=http://127.0.0.1:")
        return original_start([*arguments, "--disable-background-networking", "--disable-gpu", "--remote-debugging-port=0"])

    def menu_bind(api_name, result, *args):
        # The real callback and HMENU execute. Only the user's selection is
        # supplied without switching desktop or touching keyboard/mouse state.
        if api_name == "TrackPopupMenuEx":
            return lambda *_parameters: int((scratch / "menu-choice").read_text(encoding="ascii"))
        return user(api_name, result, *args)

    if native_launch_only and shell_win.browser_path().resolve() != browser.resolve():
        raise RuntimeError("Native launch fixture must use the browser selected by production.")
    browser_choice = nullcontext() if native_launch_only else patch.object(shell_win, "browser_path", return_value=browser)
    inspection = nullcontext() if native_launch_only else patch.object(shell_win, "_start_on_workbench_desktop", start_browser)
    with browser_choice, inspection, patch.object(shell_win, "WorkbenchWindow", ObservedWindow), patch.object(tray_win, "user", menu_bind):
        return cli.main(["--data-dir", str(data_dir), *entry_args])


def session_file(scratch, known=None):
    states = [item for item in scratch.glob("GaoCaoZuo-*.instance") if item != known]
    assert len(states) <= 1, "More than one unexpected primary instance file"
    return states[0] if states else None


def request_exit(tray, choice_file):
    choice_file.write_text("2", encoding="ascii")
    post(tray, NOTIFY_MESSAGE, (12 << 16) | 13, (1 << 16) | 0x007B)  # WM_CONTEXTMENU, icon 1


def make_ocr_request(scratch):
    from PIL import Image

    package = scratch / "synthetic.gaoaction"
    payload = package / "payload" / "synthetic-for-ocr.png"
    payload.parent.mkdir(parents=True)
    Image.new("RGB", (8, 8), "white").save(payload)
    content = payload.read_bytes()
    request_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    manifest = {"schemaVersion": 1, "kind": "request", "action": "ocr.files", "requestID": request_id,
                "sourceBundleID": "com.example.gao.fixture", "targetBundleID": "com.gaoseries.GaoCaoZuo",
                "createdAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expiresAt": (now + timedelta(seconds=110)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "nonce": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
                "parameters": {"outputs": ["text"]}, "references": [],
                "items": [{"id": "synthetic-ocr-file", "relativePath": payload.name, "uti": "public.png",
                           "sha256": hashlib.sha256(content).hexdigest(), "byteCount": len(content)}]}
    (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return package, request_id


@contextmanager
def devtools(scratch, app_port):
    import websocket

    opener = build_opener(ProxyHandler({}))

    def find_page():
        for profile in scratch.glob("GaoCaoZuo-window-*/DevToolsActivePort"):
            try:
                port = int(profile.read_text(encoding="ascii").splitlines()[0])
                with opener.open(f"http://127.0.0.1:{port}/json", timeout=.4) as response:
                    pages = json.load(response)
                for page in pages:
                    site = urlsplit(page["url"])
                    if (page["type"] == "page" and site.scheme == "http" and
                            site.netloc == f"127.0.0.1:{app_port}" and site.path == "/"):
                        return page["webSocketDebuggerUrl"]
            except (OSError, ValueError, KeyError, IndexError):
                pass
        return None

    address = until(find_page, "DevTools in the reopened private Chromium profile")
    with closing(websocket.create_connection(address, timeout=6, suppress_origin=True)) as channel:
        sequence = 0

        def command(method, parameters):
            nonlocal sequence
            sequence += 1
            channel.send(json.dumps({"id": sequence, "method": method, "params": parameters}))
            while True:
                message = json.loads(channel.recv())
                if message.get("id") == sequence:
                    result = message["result"]
                    if "exceptionDetails" in result:
                        raise AssertionError(result["exceptionDetails"])
                    return result

        def evaluate(expression):
            result = command("Runtime.evaluate", {"expression": expression, "returnByValue": True})
            return result["result"].get("value")

        yield evaluate, lambda: base64.b64decode(command("Page.captureScreenshot", {"format": "png"})["data"])


def exercise(scratch, name, desktop, browser, evidence, native_launch_only=False):
    from gaocaozuo.store import Store
    from tray_shell_fixture import ShellTrayFixture

    choice_file = scratch / "menu-choice"
    choice_file.write_text("1", encoding="ascii")
    data_dir = scratch / "test-data"
    store = Store(data_dir)
    store.create_settings()
    store.update_settings({"language": "zh-Hans", "showMenuBarIcon": False})
    short_data = scratch / "no-tray-data"
    artifact_dir = scratch / "files"
    artifact_dir.mkdir()

    def program(path, args):
        mode = ["--test-native-launch"] if native_launch_only else []
        return IsolatedProcess([EXE, __file__, "--app-child", name, scratch, path, browser, *mode, *args], name, scratch)

    with ShellTrayFixture(desktop) as explorer, ExitStack() as stack:
        primary = program(data_dir, [])
        stack.callback(primary.ensure_stopped)
        stack.callback(lambda: [post(hwnd, 0x10) for hwnd, _ in find_windows(BROWSER_TITLE)])
        descriptor = until(lambda: session_file(scratch), "the primary instance descriptor")
        address = json.loads(descriptor.read_text(encoding="utf-8"))
        port, token = address["port"], address["token"]
        first, first_pid = until(lambda: next(iter(find_windows(BROWSER_TITLE)), None), "workbench window")
        first_launcher = json.loads((scratch / "browser-launchers.jsonl").read_text(encoding="ascii").splitlines()[0])["launcherPID"]
        first_stopped = watch_process(first_pid, stack)
        hwnd, owner = until(lambda: next(iter(find_windows(TRAY_CAPTION)), None), "native tray owner")
        assert owner == primary.pid, (owner, primary.pid)

        def events(operation):
            return [item for item in explorer.operations if item.operation == operation and item.hwnd == hwnd]

        until(lambda: events(4), "real Shell_NotifyIconW version registration")
        assert len(events(0)) == 1 and events(0)[0].icon_id == 1 and events(0)[0].icon, explorer.operations
        assert http(port, token, "state")["version"].startswith("1.16+")
        http(port, token, "settings/create", {})
        before = (data_dir / "settings.json").read_bytes()
        assert json.loads(before)["showMenuBarIcon"] is False

        post(first, 0x10)  # Genuine WM_CLOSE to the actual Chromium app window.
        until(lambda: not find_windows(BROWSER_TITLE), "workbench closure")
        assert primary.poll() is None and len(events(0)) == 1
        created = http(port, token, "action", {"id": "new.text", "payload": {"directory": str(artifact_dir)}})
        saved = Path(created["result"]["path"])
        assert saved.is_file() and saved.parent == artifact_dir

        early_tray_click = not first_stopped()
        post(hwnd, NOTIFY_MESSAGE, (12 << 16) | 13, (1 << 16) | 0x0400)  # NIN_SELECT, icon 1
        reopened, reopened_pid = until(lambda: next(iter(find_windows(BROWSER_TITLE)), None), "workbench reopen from tray")
        reopened_launcher = json.loads((scratch / "browser-launchers.jsonl").read_text(encoding="ascii").splitlines()[1])["launcherPID"]
        assert reopened_pid != first_pid and len(events(0)) == 1
        until(first_stopped, "old Chromium root stopping after user closes its window")
        last_stopped = watch_process(reopened_pid, stack)
        forwarder = program(data_dir, ["--paths", str(saved)])
        stack.callback(forwarder.ensure_stopped)
        assert forwarder.wait(15) == 0
        assert http(port, token, "state")["selection"] == [str(saved)]
        assert find_windows(BROWSER_TITLE) == [(reopened, reopened_pid)] and len(events(0)) == 1

        # Neither metadata nor headless service owns an Explorer icon.
        metadata = program(short_data, ["--capabilities"])
        stack.callback(metadata.ensure_stopped)
        assert metadata.wait(10) == 0 and session_file(scratch, descriptor) is None
        headless = program(short_data, ["--serve"])
        stack.callback(headless.ensure_stopped)
        short_record = until(lambda: session_file(scratch, descriptor), "the headless instance descriptor")
        headless_address = json.loads(short_record.read_text(encoding="utf-8"))
        http(headless_address["port"], headless_address["token"], "shutdown", {})
        assert headless.wait(15) == 0
        wait_port_closed(headless_address["port"])
        assert not short_record.exists() and find_windows(TRAY_CAPTION) == [(hwnd, owner)] and len(events(0)) == 1

        explorer.taskbar_created()
        until(lambda: len(events(4)) == 2, "native icon recovery after the shell restart notification")
        assert len(events(0)) == 2 and len(explorer.icons) == 1 and explorer.icons[0].icon_id == 1

        if native_launch_only:
            request_exit(hwnd, choice_file)
            assert primary.wait(18) == 0
            until(last_stopped, "browser window owner stopping after Exit", 8)
            wait_port_closed(port)
            assert len(events(2)) == 1 and not explorer.icons and not find_windows(BROWSER_TITLE) and saved.is_file()
            return {"normalBrowserArguments": True, "browser": browser.name, "coldStart": True, "trayReopen": True,
                    "windowOwnerDifferentFromLauncher": [first_pid != first_launcher, reopened_pid != reopened_launcher],
                    "closedWindowAndSavedInBackground": True, "singleTray": True, "finishedExit": True}

        with devtools(scratch, port) as (evaluate, capture):
            until(lambda: evaluate("!!document.querySelector('.workbench-desktop-actions button')"), "desktop controls")
            evaluate("document.querySelector('.workbench-desktop-actions button').click()")
            visible = user("IsWindowVisible", w.BOOL, w.HWND)
            until(lambda: not visible(reopened), "hide to notification area")
            post(hwnd, NOTIFY_MESSAGE, (12 << 16) | 13, (1 << 16) | 0x0400)
            until(lambda: visible(reopened), "same window restored from notification area")

            package, request_id = make_ocr_request(scratch)
            protocol = program(data_dir, ["--gaoaction", str(package)])
            stack.callback(protocol.ensure_stopped)
            assert protocol.wait(15) == 0
            review_visible = "!!dialog?.open && dialog.innerText.includes('synthetic-for-ocr.png')"
            until(lambda: evaluate(review_visible), "the normal OCR request review from protocol forwarding")
            assert len(explorer.icons) == 1 and find_windows(BROWSER_TITLE) == [(reopened, reopened_pid)]
            request_exit(hwnd, choice_file)
            until(lambda: evaluate("Boolean(lifecycle.dialog?.open && dialog?.open)"), "exit review above pending confirmation")
            if evidence:
                (evidence / "exit-review-pending-confirmation.png").write_bytes(capture())
            evaluate("lifecycle.dialog.querySelector('.dialog-actions button').click()")
            until(lambda: evaluate("!lifecycle.dialog?.open && (" + review_visible + ")"),
                  "exit canceled without closing the pending confirmation")
            assert primary.poll() is None and not events(2) and len(explorer.icons) == 1
            evaluate("dialog.close()")
            observed_children = []
            for pid in descendants(reopened_pid):
                try:
                    observed_children.append(watch_process(pid, stack))
                except OSError as exc:
                    # The renderer or utility might have already exited since
                    # the snapshot. Do not replace its identity with a new PID.
                    if exc.winerror != 87:
                        raise
            request_exit(hwnd, choice_file)
        assert primary.wait(18) == 0
        until(lambda: last_stopped() and all(stopped() for stopped in observed_children), "Chromium job stopping", 8)
        wait_port_closed(port)
        assert len(events(2)) == 1 and not explorer.icons and not find_windows(TRAY_CAPTION) and not find_windows(BROWSER_TITLE)
        assert not descriptor.exists() and saved.is_file() and (data_dir / "settings.json").read_bytes() == before
        assert (data_dir / "OcrProvider" / request_id / "journal.json").is_file()
        return {"nativeShellCalls": "NIM_ADD, NIM_SETVERSION, NIM_DELETE", "isolatedShellReceiver": True,
                "browser": browser.name, "windowOwnerDifferentFromLauncher": [first_pid != first_launcher, reopened_pid != reopened_launcher],
                "realChromiumWindow": True, "singleTray": True, "oldHiddenPreferencePreserved": True,
                "closedWindowAndSavedInBackground": True,
                "trayReopenedWindow": True, "shortForwarderReusedInstance": True, "headlessNoTray": True,
                "explicitHideAndRestoreSameWindow": True,
                "earlyClickBeforeBrowserExit": early_tray_click, "pendingOcrRequestPersisted": True,
                "taskbarCreatedReregisteredSameID": True, "cancelledExitKeptSession": True,
                "confirmedExitClosedPortWindowAndProcess": True, "chromiumDescendantsObservedAndStopped": len(observed_children)}


def main():
    if os.name != "nt":
        raise SystemExit("This smoke test requires Windows.")
    if len(sys.argv) > 1 and sys.argv[1] == "--app-child":
        name, scratch, data_dir, browser = sys.argv[2:6]
        try:
            return app_child(name, Path(scratch), Path(data_dir), Path(browser), sys.argv[6:])
        except Exception:
            import traceback

            Path(scratch, f"app-failure-{os.getpid()}.txt").write_text(traceback.format_exc(), encoding="utf-8")
            return 98
    from gaocaozuo.shell_win import browser_path

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", type=Path, default=browser_path())
    parser.add_argument("--native-launch-only", action="store_true", help="Use the unmodified browser command line and validate cold start, reopen and quit.")
    parser.add_argument("--evidence", type=Path, help="Optional output directory for the synthetic exit dialog screenshot.")
    args = parser.parse_args()
    if not args.browser or not args.browser.is_file():
        parser.error("Specify an installed Chromium executable with --browser.")
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=True)
    temp = tempfile.TemporaryDirectory(prefix="GaoCaoZuo-Lifecycle-")
    scratch = Path(temp.name)
    try:
        with detached_desktop() as (name, desktop):
            try:
                result = exercise(scratch, name, desktop, args.browser.resolve(), args.evidence, args.native_launch_only)
            except Exception:
                for note in scratch.glob("app-failure-*.txt"):
                    print(note.read_text(encoding="utf-8"), file=sys.stderr)
                raise
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    finally:
        # Closing a Chromium job is asynchronous. Some private profile file
        # handles can still be closing as the last browser window disappears.
        for attempt in range(15):
            try:
                temp.cleanup()
                break
            except OSError:
                if attempt == 14:
                    raise
                time.sleep(.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
