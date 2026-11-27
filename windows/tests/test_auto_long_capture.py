import io
import os
import random

import pytest
from PIL import Image

from gaocaozuo import capture_win, screenshot
from gaocaozuo.desktop_win import WindowIdentity
from gaocaozuo.errors import AppError


@pytest.fixture
def rolling_view(tmp_path, monkeypatch):
    identity = WindowIdentity(55, 100, 101, 42, "TestScrollable", "fixture.exe")
    bounds = {"x": 10, "y": 20, "width": 60, "height": 120}
    coordinates = (10, 20, 70, 140)
    frame = (0, 0, 120, 160)
    anchor = capture_win.ScrollAnchor((34, 60), identity)
    model = {"offset": 0, "bottom": 160, "sent": 0, "foreground": 55, "covered": False, "mutated": False}
    source = Image.frombytes("RGB", (60, 280), random.Random(16).randbytes(60 * 280 * 3))

    def capture(mode, selected):
        assert mode == "region" and selected == coordinates
        y = model["offset"]
        value = source.crop((0, y, 60, y + 120))
        if model["mutated"]:
            value.putpixel((0, 0), (1, 2, 3))
        return value

    def verify(region, target, geometry, previous=None):
        assert region == coordinates and target == identity and geometry == frame and previous in (None, anchor)
        if model["foreground"] != 55 or model["covered"]:
            raise AppError("目标窗口已改变。", "targetChanged")
        return anchor

    def scroll(region, target, geometry, previous):
        verify(region, target, geometry, previous)
        model["sent"] += 1
        model["offset"] = min(model["offset"] + 40, model["bottom"])

    monkeypatch.setattr(screenshot, "_pause", lambda _delay: None)
    monkeypatch.setattr(capture_win, "window_at_center", lambda _region: identity.hwnd)
    monkeypatch.setattr(capture_win, "window_identity", lambda _hwnd: identity)
    monkeypatch.setattr(capture_win, "window_frame", lambda _hwnd: frame)
    monkeypatch.setattr(capture_win, "foreground_window", lambda: model["foreground"])
    monkeypatch.setattr(capture_win, "region_has_target", lambda _bounds, window: window == 55 and not model["covered"])
    monkeypatch.setattr(capture_win, "capture", capture)
    monkeypatch.setattr(capture_win, "verify_scroll_anchor", verify)
    monkeypatch.setattr(capture_win, "scroll_down", scroll)
    session = screenshot.ScreenshotSession(tmp_path)
    assert session.long_capture("start", True, bounds=bounds)["frames"] == 1
    return session, model, source


def test_automatic_capture_preserves_exact_pixels_and_stops_at_duplicate(rolling_view):
    session, model, source = rolling_view
    with pytest.raises(AppError, match="未明确授权"):
        session.long_capture("auto", 1, delay=0)
    assert model["sent"] == 0

    report = session.long_capture("auto", True, delay=0)
    assert report["frames"] == 5
    assert report["height"] == 280
    assert report["automatic"]["stop"] == "unchanged"
    assert report["automatic"]["added"] == 4
    assert model["sent"] == 5
    finished = session.long_capture("finish", True)
    assert Image.open(io.BytesIO(session.preview(finished["id"]))).tobytes() == source.tobytes()


def test_auto_preflight_detects_live_viewport_change_and_preserves_manual_append(rolling_view):
    session, model, _source = rolling_view
    model["offset"] = 35
    refused = session.long_capture("auto", True, delay=0)
    assert refused["frames"] == 1
    assert refused["automatic"]["stop"] == "initialChanged"
    assert model["sent"] == 0
    assert session.long_capture("append", True, delay=0)["height"] == 155


def test_auto_discards_unverified_pixels_if_target_changes_during_capture(rolling_view, monkeypatch):
    session, model, _source = rolling_view
    original = capture_win.capture

    def capture(*args):
        value = original(*args)
        if model["sent"] == 2:
            model["foreground"] = 88
        return value

    monkeypatch.setattr(capture_win, "capture", capture)
    report = session.long_capture("auto", True, delay=0)
    assert report["frames"] == 2
    assert report["height"] == 160
    assert report["automatic"]["stop"] == "targetChanged"
    assert model["sent"] == 2


def test_auto_refuses_approximate_seam_that_manual_override_can_accept(rolling_view, monkeypatch):
    session, model, _source = rolling_view
    original = capture_win.scroll_down

    def scroll(*args):
        original(*args)
        model["mutated"] = True

    monkeypatch.setattr(capture_win, "scroll_down", scroll)
    report = session.long_capture("auto", True, delay=0)
    assert report["automatic"]["stop"] == "alignment"
    assert report["frames"] == 1
    assert model["sent"] == 1
    assert session.long_capture("append", True, delay=0, overlap=80)["height"] == 160


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 native scroll transport")
def test_native_notch_delivers_signed_coordinates_to_only_the_selected_window():
    import ctypes as c
    from ctypes import wintypes as w
    from uuid import uuid4

    from gaocaozuo.native_win import kernel, user

    procedure = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    attempts = []

    @procedure
    def process_window(hwnd, message, modifiers, coordinates):
        if message == 0x020A:
            attempts.append((hwnd, c.c_short(modifiers >> 16).value, modifiers & 0xFFFF,
                             c.c_short(coordinates).value, c.c_short(coordinates >> 16).value))
            return 0
        return default(hwnd, message, modifiers, coordinates)

    class WindowClass(c.Structure):
        _fields_ = [("style", w.UINT), ("procedure", procedure), ("class_extra", c.c_int), ("window_extra", c.c_int),
                    ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                    ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]

    instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
    name = "GaoScreenshotScrollTest" + uuid4().hex
    descriptor = WindowClass(procedure=process_window, instance=instance, name=name)
    register = user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))
    create = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int, c.c_int, c.c_int,
                  w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
    if not register(c.byref(descriptor)):
        pytest.skip(f"This Windows session does not allow message-only window classes ({c.get_last_error()}).")
    targets = []
    try:
        for _ in range(2):
            target = create(0, name, None, 0, 0, 0, 0, 0, c.c_void_p(-3), None, instance, None)
            if not target:
                pytest.skip(f"This Windows session does not allow message-only windows ({c.get_last_error()}).")
            targets.append(target)
        assert capture_win._send_scroll_notch(targets[0], (-200, -900))
        assert attempts == [(targets[0], -120, 0, -200, -900)]
        assert not capture_win._send_scroll_notch(targets[1], (-32769, 900))
        assert len(attempts) == 1
    finally:
        for target in targets:
            user("DestroyWindow", w.BOOL, w.HWND)(target)
        user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(name, instance)
