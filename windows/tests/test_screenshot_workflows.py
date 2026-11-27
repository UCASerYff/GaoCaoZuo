import base64
import hashlib
import io
import json
import os
import queue
import random
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from PIL import Image, ImageDraw, ImageFont

from gaocaozuo.errors import AppError
from gaocaozuo.ocr_provider import OcrProvider
from gaocaozuo.screenshot import ScreenshotSession


@pytest.fixture(autouse=True)
def isolated_ocr_return_base(tmp_path, monkeypatch):
    root = tmp_path / "LocalAppData"
    root.mkdir()
    monkeypatch.setenv("LOCALAPPDATA", str(root))


def test_annotate_transform_save_and_reopen(tmp_path):
    session = ScreenshotSession(tmp_path / "data")
    source = session.capture(True, lambda: (120, 80, bytes([255, 255, 255]) * 120 * 80))
    changed = session.annotate(source["id"], [], [
        {"type": "redact", "x": 3, "y": 5, "x2": 39, "y2": 35, "color": "#000000"},
        {"type": "crop", "x": 0, "y": 0, "x2": 40, "y2": 30},
        {"type": "rotate", "degrees": 90},
    ])
    assert (changed["width"], changed["height"]) == (30, 40)
    raw = Image.open(io.BytesIO(session.preview(source["id"])))
    annotated = Image.open(io.BytesIO(session.preview(changed["id"])))
    assert raw.getpixel((10, 20)) == (255, 255, 255)
    assert annotated.getpixel((10, 15)) == (0, 0, 0)
    editor_path = Path(session.save(changed["id"], tmp_path, "editable.gaowinannotation"))
    reopened = ScreenshotSession(tmp_path / "data")
    assert reopened.preview(reopened.open(editor_path)["id"]) == session.preview(changed["id"])
    with pytest.raises(AppError, match="已经|已存在"):
        session.save(changed["id"], tmp_path, "editable.gaowinannotation")


def test_capture_history_is_opt_in_and_reopens_legacy_records(tmp_path):
    session = ScreenshotSession(tmp_path)
    capture = lambda: (20, 25, bytes([33, 44, 55]) * 20 * 25)
    assert session.capture(True, capture)["saved"] is None
    assert not (tmp_path / "ScreenshotHistory").exists()
    assert session.history(enabled=True)["enabled"]
    result = session.capture(True, capture)
    assert Path(result["saved"]).is_file()
    next_session = ScreenshotSession(tmp_path)
    assert next_session.history()["enabled"]
    item = next_session.history()["items"][0]
    assert next_session.history_open(item["name"])["height"] == 25
    assert next_session.history(enabled=False)["items"] == [item]


def test_manual_long_capture_guards_target_and_aligns_real_pixels(tmp_path, monkeypatch):
    from gaocaozuo import capture_win

    session = ScreenshotSession(tmp_path)
    source = Image.frombytes("RGB", (60, 280), random.Random(16).randbytes(60 * 280 * 3))
    frames = iter((source.crop((0, 0, 60, 160)), source.crop((0, 120, 60, 280))))
    monkeypatch.setattr(capture_win, "window_at_center", lambda _bounds: 55)
    monkeypatch.setattr(capture_win, "window_identity", lambda _hwnd: (100, 101))
    monkeypatch.setattr(capture_win, "region_has_target", lambda _bounds, window: window == 55)
    monkeypatch.setattr(capture_win, "foreground_window", lambda: 66)
    monkeypatch.setattr(capture_win, "capture", lambda *_: next(frames))
    bounds = {"x": 10, "y": 20, "width": 60, "height": 160}
    with pytest.raises(AppError, match="未明确授权"):
        session.long_capture("start", False, bounds=bounds)
    assert session.long_capture("start", True, bounds=bounds)["frames"] == 1
    with pytest.raises(AppError, match="目标窗口已改变"):
        session.long_capture("append", True, delay=0)
    monkeypatch.setattr(capture_win, "foreground_window", lambda: 55)
    assert session.long_capture("append", True, delay=0)["height"] == 280
    result = session.long_capture("finish", True)
    assert Image.open(io.BytesIO(session.preview(result["id"]))).tobytes() == source.tobytes()


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 GDI")
def test_printwindow_reads_only_synthetic_window_on_separate_desktop():
    import ctypes as c
    from ctypes import wintypes as w

    from gaocaozuo.capture_win import _capture_window, capture
    from gaocaozuo.native_win import bind, is_input_desktop, kernel, user

    make_desktop = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)
    handle = make_desktop("GaoCaptureTest-" + uuid.uuid4().hex, None, None, 0, 0x000F01FF, None)
    if not handle:
        pytest.skip(f"The current Windows session does not allow an isolated desktop ({c.get_last_error()}).")
    out = queue.Queue()
    wndproc = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

    class WindowClass(c.Structure):
        _fields_ = [("style", w.UINT), ("wndproc", wndproc), ("classExtra", c.c_int), ("windowExtra", c.c_int),
                    ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                    ("menuName", w.LPCWSTR), ("className", w.LPCWSTR)]

    def exercise():
        hwnd = brush = instance = None
        klass = "GaoCaptureFixture-" + uuid.uuid4().hex
        try:
            assert user("SetThreadDesktop", w.BOOL, w.HANDLE)(handle)
            assert not is_input_desktop()
            assign_window = user("CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                                 c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            instance = kernel("GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
            brush = bind("gdi32", "CreateSolidBrush", w.HBRUSH, w.DWORD)(0x75AC21)
            fill = user("FillRect", c.c_int, w.HDC, c.POINTER(w.RECT), w.HBRUSH)
            default = user("DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

            @wndproc
            def paint(window, message, wparam, lparam):
                if message in (0x0317, 0x0318):  # WM_PRINT, WM_PRINTCLIENT
                    fill(wparam, c.byref(w.RECT(0, 0, 320, 180)), brush)
                    return 0
                return default(window, message, wparam, lparam)

            descriptor = WindowClass(wndproc=paint, instance=instance, className=klass)
            assert user("RegisterClassW", w.ATOM, c.POINTER(WindowClass))(c.byref(descriptor))
            hwnd = assign_window(0, klass, "Synthetic capture fixture", 0x90000000, 50, 50, 320, 180,
                                 None, None, instance, None)
            assert hwnd
            for mode in ("window", "region", "display", "virtual"):
                with pytest.raises(AppError) as blocked:
                    capture(mode, hwnd=hwnd)
                assert blocked.value.code == "unavailable"
            try:
                output = _capture_window(hwnd)
            except AppError as exc:
                if exc.code == "rejected" and "全黑画面" in exc.message:
                    out.put("An unswitched Windows desktop returned a black compositor surface. Interactive capture is blocked and synthetic low-level rendering remains unverified.")
                    return
                raise
            assert output.size == (320, 180)
            assert output.getpixel((160, 90)) == (0x21, 0xAC, 0x75)
            out.put(None)
        except BaseException as exc:
            out.put(exc)
        finally:
            if hwnd:
                user("DestroyWindow", w.BOOL, w.HWND)(hwnd)
            if instance:
                user("UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(klass, instance)
            if brush:
                bind("gdi32", "DeleteObject", w.BOOL, w.HANDLE)(brush)

    thread = threading.Thread(target=exercise, daemon=True)
    try:
        thread.start()
        thread.join(timeout=10)
        assert not thread.is_alive(), "Synthetic PrintWindow timed out"
        failure = out.get_nowait()
        if isinstance(failure, str):
            pytest.skip(failure)
        if failure:
            raise failure
    finally:
        user("CloseDesktop", w.BOOL, w.HANDLE)(handle)


def _request(tmp_path, stamp, binary, name="a.png", relative=None):
    request = tmp_path / "Request.gaoaction"
    (request / "payload").mkdir(parents=True)
    (request / "payload" / name).write_bytes(binary)
    identifier = str(uuid.uuid4())
    manifest = {
        "schemaVersion": 1, "kind": "request", "requestID": identifier, "sourceBundleID": "com.gaoseries.GaoWenJian",
        "targetBundleID": "com.gaoseries.GaoCaoZuo", "action": "ocr.files",
        "createdAt": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), "expiresAt": (stamp + timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nonce": base64.b64encode(os.urandom(32)).decode("ascii"), "references": [],
        "parameters": {"outputs": ["text", "json", "searchablePDF"]},
        "items": [{"relativePath": relative or name, "uti": "public.png", "id": "input-item", "byteCount": len(binary),
                   "sha256": hashlib.sha256(binary).hexdigest()}],
    }
    (request / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return request, manifest


@pytest.mark.parametrize("relative", ["../a.png", "CON.png", "folder/../a.png", "a.png:stream", "//a.png"])
def test_ocr_provider_rejects_unsafe_windows_attachment_paths(tmp_path, relative):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    path, manifest = _request(tmp_path, now, b"synthetic", relative=relative)
    provider = OcrProvider(tmp_path / "isolated", clock=lambda: now)
    with pytest.raises(AppError) as error:
        provider.receive(path)
    assert error.value.code == "unsafe"
    assert provider.jobs() == []


@pytest.mark.skipif(os.name != "nt", reason="requires Windows file timestamps")
def test_ocr_provider_accepts_stable_files_with_distinct_windows_timestamps(tmp_path):
    import ctypes as c
    import msvcrt
    from ctypes import wintypes as w

    from gaocaozuo.native_win import kernel

    now = datetime.now(timezone.utc).replace(microsecond=0)
    binary = b"unchanged attachment"
    source, manifest = _request(tmp_path, now, binary)
    set_time = kernel("SetFileTime", w.BOOL, w.HANDLE, c.POINTER(w.FILETIME), c.POINTER(w.FILETIME), c.POINTER(w.FILETIME))
    creation_ticks = 133_485_408_001_234_567  # 2024-01-01 in 100 ns FILETIME ticks.
    birth = w.FILETIME(creation_ticks & 0xFFFFFFFF, creation_ticks >> 32)
    for path in (source / "manifest.json", source / "payload" / "a.png"):
        with path.open("r+b") as stream:
            assert set_time(msvcrt.get_osfhandle(stream.fileno()), c.byref(birth), c.byref(birth), None)

    provider = OcrProvider(tmp_path / "isolated", clock=lambda: now)
    review = provider.receive(source)
    assert review["requestID"] == manifest["requestID"]
    assert review["status"] == "pending"
    assert provider.receive(source) == review
    assert provider.jobs() == [review]


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 file sharing")
def test_ocr_provider_pins_windows_path_during_attachment_read(tmp_path, monkeypatch):
    from gaocaozuo import ocr_provider

    now = datetime.now(timezone.utc).replace(microsecond=0)
    data = b"original attachment"
    source, _ = _request(tmp_path, now, data)
    attachment = source.resolve() / "payload" / "a.png"
    replacement = tmp_path / "different-file.png"
    replacement.write_bytes(data)
    open_windows_file = ocr_provider._open_windows_file
    checked = False

    @contextmanager
    def verify_sharing(path):
        nonlocal checked
        with open_windows_file(path) as stream:
            if path == attachment and not checked:
                with pytest.raises(PermissionError):
                    replacement.replace(attachment)
                with pytest.raises(PermissionError):
                    attachment.write_bytes(b"modified attachment")
                checked = True
            yield stream

    monkeypatch.setattr(ocr_provider, "_open_windows_file", verify_sharing)
    provider = OcrProvider(tmp_path / "isolated", clock=lambda: now)
    assert provider.receive(source)["status"] == "pending"
    assert checked and replacement.read_bytes() == data and attachment.read_bytes() == data


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 file identity")
def test_ocr_provider_path_recheck_distinguishes_identical_windows_files(tmp_path):
    from gaocaozuo import ocr_provider

    path, replacement = tmp_path / "same-name.bin", tmp_path / "replacement.bin"
    data = b"same attachment bytes"
    path.write_bytes(data)
    replacement.write_bytes(data)
    with ocr_provider._open_windows_file(path) as stream:
        before = ocr_provider._windows_file_snapshot(stream, path)
    replacement.replace(path)
    with ocr_provider._open_windows_file(path) as stream:
        after = ocr_provider._windows_file_snapshot(stream, path)
    assert before[1] != after[1]
    assert path.read_bytes() == data
    # Isolate the actual native identity from other metadata a replacement may update.
    expected = (after[0], before[1], *after[2:])
    with pytest.raises(AppError) as error:
        ocr_provider._check_current_path(path, expected)
    assert error.value.code == "changed"


@pytest.mark.skipif(os.name != "nt", reason="requires Win32 link-count validation")
def test_ocr_provider_rejects_hard_linked_windows_attachment(tmp_path):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    source, _ = _request(tmp_path, now, b"original attachment")
    os.link(source / "payload" / "a.png", tmp_path / "alias.png")
    provider = OcrProvider(tmp_path / "isolated", clock=lambda: now)
    with pytest.raises(AppError) as error:
        provider.receive(source)
    assert error.value.code == "unsafe"
    assert provider.jobs() == []


def _rewrite_preserving_size_and_mtime(path, content):
    before = path.stat()
    assert len(content) == before.st_size
    path.write_bytes(content)
    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
    assert path.stat().st_mtime_ns == before.st_mtime_ns


def test_ocr_provider_rejects_changed_source_digest_before_staging(tmp_path):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    source, _ = _request(tmp_path, now, b"original attachment")
    _rewrite_preserving_size_and_mtime(source / "payload" / "a.png", b"modified attachment")
    provider = OcrProvider(tmp_path / "isolated", clock=lambda: now)
    with pytest.raises(AppError) as error:
        provider.receive(source)
    assert error.value.code == "changed"
    assert provider.jobs() == []


def test_ocr_provider_rechecks_staged_input_before_approval(tmp_path):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    path, manifest = _request(tmp_path, now, b"staged attachment")
    directory = tmp_path / "isolated"

    def start_ocr():
        pytest.fail("OCR must not consume a staged attachment that changed after review")

    provider = OcrProvider(directory, clock=lambda: now, session_factory=start_ocr)
    review = provider.receive(path)
    staged = directory / "OcrProvider" / manifest["requestID"] / "input-1.bin"
    _rewrite_preserving_size_and_mtime(staged, b"altered contents!")
    with pytest.raises(AppError) as error:
        provider.approve(review["requestID"], True)
    assert error.value.code == "changed"
    assert provider.jobs() == [review]


@pytest.mark.skipif(os.name != "nt", reason="requires Windows.Media.Ocr")
def test_windows_native_ocr_pdf_and_gaoaction_handoff(tmp_path):
    from gaocaozuo.ocr import _helper_binary

    try:
        _helper_binary()
    except AppError:
        pytest.skip("Build the Windows OCR helper to run the native engine fixture.")
    session = ScreenshotSession(tmp_path / "iso")
    languages = session.ocr_languages()["languages"]
    if not languages:
        pytest.skip("The fixture host has no installed Windows OCR language.")
    image = Image.new("RGB", (1000, 260), "white")
    ImageDraw.Draw(image).text((60, 80), "12345 67890", fill="black", font=ImageFont.truetype("arial.ttf", 80))
    png, pdf = tmp_path / "fixture.png", tmp_path / "fixture.pdf"
    image.save(png)
    Image.init()  # The PDF writer uses the JPEG encoder, even when this test runs alone.
    image.save(pdf)
    document = session.ocr(True, paths=[png, pdf], languages=languages[:1])
    assert document["status"] == "completed"
    assert all("12345" in source["pages"][0]["text"].replace(" ", "") for source in document["sources"])
    result = session.ocr_export(document["id"], tmp_path, "searchablePDF")
    exported = Path(result["path"]).read_bytes()
    assert exported.startswith(b"%PDF-1.7") and b"/ToUnicode" in exported and b"/Count 2" in exported

    now = datetime.now(timezone.utc).replace(microsecond=0)
    path, request = _request(tmp_path, now, png.read_bytes())
    provider = OcrProvider(tmp_path / "isolated-provider", clock=lambda: now)
    review = provider.receive(path)
    assert review["status"] == "pending" and review["resultCount"] == 0
    identifier = review["requestID"]
    with pytest.raises(AppError) as error:
        provider.approve(identifier, False)
    assert error.value.code == "unauthorized"
    approved = provider.approve(identifier, True)
    assert approved["status"] == "completed" and provider.receive(path) == approved
    result = provider.export_result(identifier, tmp_path / "response", True)
    result_dir = Path(result["path"])
    manifest = json.loads((result_dir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["inReplyTo"] == identifier
    assert manifest["sourceBundleID"] == request["targetBundleID"]
    assert manifest["targetBundleID"] == request["sourceBundleID"]
    assert manifest["provenance"]["networkUsed"] is False
    assert len(manifest["items"]) == 3
    assert {item["sourceItemID"] for item in manifest["provenance"]["outputs"]} == {"input-item"}
    for item in manifest["items"]:
        data = (result_dir / "payload" / item["relativePath"]).read_bytes()
        assert len(data) == item["byteCount"] and hashlib.sha256(data).hexdigest() == item["sha256"]
