"""Opt-in Windows foreground assent check. Only a synthetic document is captured or scrolled."""

from __future__ import annotations

import argparse
import ctypes as c
import ctypes.wintypes as w
import io
import json
import os
import random
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from gaocaozuo import capture_win
from gaocaozuo.desktop_win import physical_coordinates
from gaocaozuo.errors import AppError
from gaocaozuo.native_win import bind, is_input_desktop, is_session_active, kernel, user
from gaocaozuo.platform_win import last_input
from gaocaozuo.screenshot import ScreenshotSession


WIDTH, VIEWPORT, PAGE = 380, 280, 550
INSET, STEP, REQUIRED_IDLE = 22, 54, 45
PIN_TITLE = "搞操作 · 贴图"


def synthetic_document() -> Image.Image:
    data = random.Random(324).randbytes(WIDTH * PAGE * 3)
    return Image.frombytes("RGB", (WIDTH, PAGE), data)


def offscreen_document() -> Image.Image:
    image = Image.new("RGB", (WIDTH, PAGE), (37, 167, 72))
    image.paste((189, 52, 86), (0, 0, WIDTH // 3, PAGE))
    image.paste((44, 83, 192), (2 * WIDTH // 3, 0, WIDTH, PAGE))
    return image


def serve_document(startup: Path, name: str, x: int, y: int, activate: bool = True) -> None:
    class Paint(c.Structure):
        _fields_ = [("dc", w.HDC), ("erase", w.BOOL), ("region", w.RECT), ("restore", w.BOOL),
                    ("update", w.BOOL), ("reserved", c.c_byte * 32)]

    callback = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

    class WindowClass(c.Structure):
        _fields_ = [("style", w.UINT), ("procedure", callback), ("class_extra", c.c_int), ("window_extra", c.c_int),
                    ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                    ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]

    default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    invalidate = user("InvalidateRect", w.BOOL, w.HWND, c.POINTER(w.RECT), w.BOOL)
    update = user("UpdateWindow", w.BOOL, w.HWND)
    document = synthetic_document() if activate else offscreen_document()
    position = 0
    bitmap = capture_win.BitmapInfo(size=40, width=WIDTH, height=-VIEWPORT, planes=1, bits=32)
    stretch = bind("gdi32", "StretchDIBits", c.c_int, w.HDC, *([c.c_int] * 8), w.LPCVOID,
                   c.POINTER(capture_win.BitmapInfo), w.UINT, w.DWORD)

    def draw(dc):
        data = document.crop((0, position, WIDTH, position + VIEWPORT)).tobytes("raw", "BGRX")
        if stretch(dc, 0, 0, WIDTH, VIEWPORT, 0, 0, WIDTH, VIEWPORT, data, c.byref(bitmap), 0, 0x00CC0020) != VIEWPORT:
            raise RuntimeError("Synthetic window was not painted.")

    @callback
    def process(hwnd, message, first, second):
        nonlocal position
        if message == 0x000F:
            paint = Paint()
            dc = user("BeginPaint", w.HDC, w.HWND, c.POINTER(Paint))(hwnd, c.byref(paint))
            if dc:
                try:
                    draw(dc)
                finally:
                    user("EndPaint", w.BOOL, w.HWND, c.POINTER(Paint))(hwnd, c.byref(paint))
            return 0
        if message == 0x0317:  # WM_PRINT, for the ordinary Window capture entry.
            draw(first)
            return 0
        if message == 0x020A and c.c_short(first >> 16).value == -120:
            position = min(PAGE - VIEWPORT, position + STEP)
            invalidate(hwnd, None, False)
            update(hwnd)
            return 0
        if message == 0x0002:
            user("PostQuitMessage", None, c.c_int)(0)
            return 0
        return default(hwnd, message, first, second)

    user("SetProcessDpiAwarenessContext", w.BOOL, w.HANDLE)(c.c_void_p(-4))
    instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
    window_class = WindowClass(procedure=process, instance=instance, name=name)
    if not user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))(c.byref(window_class)):
        raise RuntimeError("Unable to register the synthetic window.")
    try:
        create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                      c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
        # WS_EX_NOACTIVATE prevents the off-screen fixture from taking focus or
        # appearing on the taskbar; its position is verified before capture.
        hwnd = create(0 if activate else 0x08000000, name, name, 0x80000000, x, y, WIDTH, VIEWPORT,
                      None, None, instance, None)
        if not hwnd:
            raise RuntimeError(f"Synthetic HWND creation was refused ({c.get_last_error()}).")
        user("ShowWindow", w.BOOL, w.HWND, c.c_int)(hwnd, 1 if activate else 8)
        if activate:
            user("SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT)(
                hwnd, c.c_void_p(-1), 0, 0, 0, 0, 0x0003
            )
            user("SetForegroundWindow", w.BOOL, w.HWND)(hwnd)
        update(hwnd)
        capture_win._flush_desktop()
        startup.write_text(json.dumps({"hwnd": hwnd, "pid": os.getpid()}), encoding="utf-8")
        message = w.MSG()
        while user("GetMessageW", c.c_int, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)(c.byref(message), None, 0, 0) > 0:
            user("DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))(c.byref(message))
    finally:
        user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(name, instance)


def visible_own_pins() -> list[int]:
    handles = []
    callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)

    @callback
    def visit(hwnd, _argument):
        pid = w.DWORD()
        user("GetWindowThreadProcessId", w.DWORD, w.HWND, w.LPDWORD)(hwnd, c.byref(pid))
        if pid.value == os.getpid():
            title = c.create_unicode_buffer(100)
            user("GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)(hwnd, title, len(title))
            if title.value == PIN_TITLE and user("IsWindowVisible", w.BOOL, w.HWND)(hwnd):
                handles.append(hwnd)
        return True

    user("EnumWindows", w.BOOL, callback, w.LPARAM)(visit, 0)
    return handles


def wait_until(predicate, limit=5):
    until = time.monotonic() + limit
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    return None


@contextmanager
def offscreen_fixture(directory: Path):
    if not is_input_desktop() or not is_session_active():
        raise RuntimeError("The test host is not on the active ordinary Windows desktop.")
    with physical_coordinates():
        screen = capture_win.desktop_bounds()
    startup = directory / "offscreen-hwnd.json"
    title = f"GaoMediaOnlyFixture-{os.getpid()}-{time.monotonic_ns()}"
    # Start the interpreter directly. The Windows venv shim would otherwise own job.pid.
    interpreter = getattr(sys, "_base_executable", sys.executable)
    fixture_env = {**os.environ, "PYTHONPATH": os.pathsep.join(path for path in sys.path if path)}
    job = subprocess.Popen([interpreter, str(Path(__file__).resolve()), "--child", str(startup), title,
                            str(screen[2] + 64), str(screen[1]), "--passive-child"],
                           creationflags=subprocess.CREATE_NO_WINDOW, env=fixture_env)
    hwnd = None
    try:
        if not wait_until(lambda: startup.exists() and startup.stat().st_size > 0):
            raise RuntimeError("The off-screen fixture did not report its window handle.")
        hwnd = json.loads(startup.read_text(encoding="utf-8"))["hwnd"]
        identity = capture_win.window_identity(hwnd)
        if identity is None or identity.pid != job.pid or identity.class_name != title:
            raise RuntimeError("The off-screen fixture window identity changed.")
        verify_offscreen_bound(hwnd)
        yield hwnd, title
        verify_offscreen_bound(hwnd)
    finally:
        if hwnd and job.poll() is None:
            identity = capture_win.window_identity(hwnd)
            if identity is not None and identity.pid == job.pid and identity.class_name == title:
                user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)(hwnd, 0x0010, 0, 0)
        try:
            job.wait(3)
        except subprocess.TimeoutExpired:
            job.terminate()
            job.wait(3)


def verify_offscreen_bound(hwnd):
    with physical_coordinates():
        frame = capture_win.window_frame(hwnd)
        if not frame or frame[0] <= capture_win.desktop_bounds()[2] or capture_win.foreground_window() == hwnd:
            raise RuntimeError("The synthetic window boundary or foreground state did not pass validation.")


def exercise_offscreen(directory: Path):
    with offscreen_fixture(directory) as (hwnd, _title):
        session = ScreenshotSession(directory / "data")
        result = session.capture(True, mode="window", window_id=hwnd)
        with Image.open(io.BytesIO(session.preview(result["id"]))) as captured:
            expected = offscreen_document().crop((0, 0, WIDTH, VIEWPORT))
            assert captured.size == expected.size and captured.tobytes() == expected.tobytes(), "Off-screen fixture pixels differ."
        return {"offscreenWindowPixels": [WIDTH, VIEWPORT], "foregroundActivated": False,
                "captureTarget": "verified synthetic HWND only"}


def exercise(directory: Path) -> dict:
    if not is_input_desktop() or not is_session_active():
        raise RuntimeError("The session is not the active ordinary Windows input desktop.")
    initial_tick, idle = last_input()
    if idle < REQUIRED_IDLE:
        raise RuntimeError(f"User activity was detected {idle:.1f}s ago; the synthetic window was not opened.")
    original_window = capture_win.foreground_window()
    get_cursor = user("GetPhysicalCursorPos", w.BOOL, c.POINTER(w.POINT))
    original = w.POINT()
    if not get_cursor(c.byref(original)):
        raise RuntimeError("Unable to locate the initial cursor.")

    class MonitorInfo(c.Structure):
        _fields_ = [("size", w.DWORD), ("monitor", w.RECT), ("work", w.RECT), ("flags", w.DWORD)]

    monitor = user("MonitorFromPoint", w.HANDLE, w.POINT, w.DWORD)(original, 0)
    info = MonitorInfo(size=c.sizeof(MonitorInfo))
    if not monitor or not user("GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(MonitorInfo))(monitor, c.byref(info)):
        raise RuntimeError("Unable to locate the monitor under the cursor.")
    box = info.monitor
    x = min(max(original.x - WIDTH // 2, box.left), box.right - WIDTH)
    y = min(max(original.y - VIEWPORT // 2, box.top), box.bottom - VIEWPORT)
    if not (x + INSET <= original.x < x + WIDTH - INSET and y + INSET <= original.y < y + VIEWPORT - INSET):
        raise RuntimeError("The cursor rests too near the monitor edge for the isolated region without moving the cursor.")
    process = None
    synthetic = None
    post = user("PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    startup = directory / "hwnd.json"
    name = f"GaoCaoZuoSyntheticScroll_{os.getpid()}_{time.monotonic_ns()}"
    try:
        if last_input()[0] != initial_tick or not is_input_desktop():
            raise RuntimeError("Activity or desktop changed before launching the synthetic window.")
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--child", str(startup), name, str(x), str(y)],
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        if not wait_until(lambda: startup.exists() and startup.stat().st_size > 0):
            raise RuntimeError("The synthetic window did not report its handle.")
        synthetic = json.loads(startup.read_text(encoding="utf-8"))["hwnd"]
        identity = capture_win.window_identity(synthetic)
        if identity is None or identity.pid != process.pid or identity.class_name != name:
            raise RuntimeError("Synthetic window identity does not match the launched process.")
        if not wait_until(lambda: capture_win.foreground_window() == synthetic, 1):
            raise RuntimeError("Windows did not allow the synthetic window to enter the foreground.")
        if last_input()[0] != initial_tick:
            raise RuntimeError("New user input arrived while the synthetic window was being created.")
        frame = capture_win.window_frame(synthetic)
        if frame is None or (frame[2] - frame[0], frame[3] - frame[1]) != (WIDTH, VIEWPORT):
            raise RuntimeError("Synthetic window has unexpected physical bounds.")
        left, top = frame[0] + INSET, frame[1] + INSET
        region = left, top, frame[2] - INSET, frame[3] - INSET
        bounds = dict(x=left, y=top, width=WIDTH - INSET * 2, height=VIEWPORT - INSET * 2)
        if capture_win.window_at_center(region) != synthetic or not capture_win.region_has_target(region, synthetic):
            raise RuntimeError("Native hit tests did not place all sampled pixels on the synthetic window.")
        if not capture_win._visible_region(region, synthetic):
            raise RuntimeError("The synthetic region may be occluded by another window; no pixels were read.")
        capture_win.verify_scroll_anchor(region, identity, frame)
        session = ScreenshotSession(directory / "data")
        document = synthetic_document()
        expected_first = document.crop((INSET, INSET, WIDTH - INSET, VIEWPORT - INSET))
        try:
            captured = session.capture(True, mode="region", bounds=bounds)
            capture_win.verify_scroll_anchor(region, identity, frame)
        except AppError as exc:
            raise RuntimeError(f"Synthetic region capture was refused: {exc.message}") from exc
        assert Image.open(io.BytesIO(session.preview(captured["id"]))).tobytes() == expected_first.tobytes(), "Region pixels differed from the synthetic document."
        assert last_input()[0] == initial_tick, "User input changed during synthetic capture."
        window = session.capture(True, mode="window", window_id=synthetic)
        assert Image.open(io.BytesIO(session.preview(window["id"]))).tobytes() == document.crop((0, 0, WIDTH, VIEWPORT)).tobytes(), "Window pixels differed from the synthetic document."
        capture_win.verify_scroll_anchor(region, identity, frame)
        session.long_capture("start", True, bounds=bounds)
        rolled = session.long_capture("auto", True, delay=0)
        assert rolled["automatic"]["added"] == 5 and rolled["automatic"]["stop"] == "unchanged", rolled
        assert last_input()[0] == initial_tick, "User input changed during the synthetic scrolling test."
        long_image = session.long_capture("finish", True)
        expected_full = document.crop((INSET, INSET, WIDTH - INSET, PAGE - INSET))
        assert Image.open(io.BytesIO(session.preview(long_image["id"]))).tobytes() == expected_full.tobytes(), "Automatic long capture did not match the full synthetic document."
        saved_path = Path(session.pin(captured["id"], persistent=True))
        assert Image.open(saved_path).tobytes() == expected_first.tobytes(), "Persisted pin differs from the verified capture."
        pins = wait_until(visible_own_pins)
        assert pins and len(pins) == 1, "Exactly one synthetic top-level pin must be visible."
        assert user("GetWindowLongW", c.c_long, w.HWND, c.c_int)(pins[0], -20) & 8, "Synthetic pin is not topmost."
        assert post(pins[0], 0x0010, 0, 0), "Synthetic pin close was refused."
        assert wait_until(lambda: not visible_own_pins()), "Synthetic pin did not close."
        restored = session.restore_pins([saved_path.name])
        assert len(restored["opened"]) == 1 and not restored["failures"], restored
        assert wait_until(visible_own_pins), "Restored synthetic pin was never visible."
        return {"regionPixels": list(expected_first.size), "windowPixels": [WIDTH, VIEWPORT],
                "longFrames": rolled["frames"], "longPixels": list(expected_full.size), "longStop": rolled["automatic"]["stop"],
                "pinVisibleAndTopmost": True, "pinRestored": True}
    finally:
        for hwnd in visible_own_pins():
            post(hwnd, 0x0010, 0, 0)
        if process:
            target_foreground = synthetic is not None and capture_win.foreground_window() == synthetic
            if synthetic and process.poll() is None:
                identity = capture_win.window_identity(synthetic)
                if identity is not None and identity.pid == process.pid and identity.class_name == name:
                    post(synthetic, 0x0010, 0, 0)
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(3)
            unchanged = is_input_desktop() and last_input()[0] == initial_tick
            if unchanged and target_foreground and original_window and capture_win.foreground_window() in (0, synthetic):
                user("SetForegroundWindow", w.BOOL, w.HWND)(original_window)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--child", nargs=4, help=argparse.SUPPRESS)
    parser.add_argument("--passive-child", action="store_true", help=argparse.SUPPRESS)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--run", action="store_true")
    scope.add_argument("--offscreen-window", action="store_true", help="Capture only a nonactivating synthetic window beyond every display")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required.")
    if args.child:
        serve_document(Path(args.child[0]), args.child[1], int(args.child[2]), int(args.child[3]), activate=not args.passive_child)
        return
    if not (args.run or args.offscreen_window):
        parser.error("Choose --offscreen-window, or use --run with a coordinated foreground slot.")
    try:
        with tempfile.TemporaryDirectory(prefix="gaocaozuo-synthetic-window-") as path, physical_coordinates():
            check = exercise_offscreen if args.offscreen_window else exercise
            print(json.dumps(check(Path(path)), ensure_ascii=False))
    except (RuntimeError, AppError) as exc:
        parser.exit(2, f"Foreground test stopped: {exc}\n")


if __name__ == "__main__":
    main()
