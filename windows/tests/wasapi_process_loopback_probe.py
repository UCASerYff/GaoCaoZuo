"""Opt-in WASAPI diagnostic. Captures only its synthetic child renderer.

The private, nonpersistent renderer is muted in --run-muted mode. Separate
--run-subthreshold consent permits a 300 ms floating-point pulse capped at
-160 dBFS in that new session. No endpoint-wide capture or volume changes.
"""

from __future__ import annotations

import argparse
from array import array
from contextlib import contextmanager
import ctypes as c
import ctypes.wintypes as w
import json
import math
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import uuid


HRESULT, POINTER = c.c_long, c.c_void_p
DWORD, BUFFER_TIME = w.DWORD, c.c_longlong
RATE, TONE = 44100, 733
FLOAT_PEAK = 1e-8
FLOAT_FRAMES = RATE * 3 // 10
LOOPBACK = 0x00020000
RENDER_FLAGS = 0x80000000 | 0x08000000 | 0x00080000  # PCM conversion, quality, private nonpersistent session
_pending = []


class Guid(c.Structure):
    _fields_ = [("first", w.DWORD), ("second", w.WORD), ("third", w.WORD), ("tail", c.c_ubyte * 8)]


def guid(text):
    return Guid.from_buffer_copy(uuid.UUID(text).bytes_le)


IID_CLIENT = guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")
IID_RENDER = guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2")
IID_CAPTURE = guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317")
IID_VOLUME = guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")


class WaveFormat(c.Structure):
    _pack_ = 1
    _fields_ = [("tag", w.WORD), ("channels", w.WORD), ("rate", DWORD), ("byte_rate", DWORD),
                ("alignment", w.WORD), ("bits", w.WORD), ("extra", w.WORD)]


PCM16 = WaveFormat(1, 2, RATE, RATE * 4, 4, 16, 0)
FLOAT32 = WaveFormat(3, 2, RATE, RATE * 8, 8, 32, 0)


def check(status, operation):
    if status < 0:
        raise RuntimeError(f"{operation} HRESULT=0x{status & 0xffffffff:08x}")


def call(interface, slot, argtypes=(), *args, result=HRESULT):
    entry = c.cast(interface, c.POINTER(c.POINTER(POINTER))).contents[slot]
    return c.WINFUNCTYPE(result, POINTER, *argtypes)(entry)(interface, *args)


def release(interface):
    if interface:
        call(interface, 2, result=w.ULONG)


@contextmanager
def com_session():
    ole = c.WinDLL("ole32")
    check(ole.CoInitializeEx(None, 0), "CoInitializeEx")
    try:
        yield ole
    finally:
        ole.CoUninitialize()


def initialize(client, flags, wave_format, session=None):
    check(call(client, 3, (c.c_int, DWORD, BUFFER_TIME, BUFFER_TIME, POINTER, POINTER),
               0, flags, 2000000, 0, c.byref(wave_format), c.byref(session) if session else None), "IAudioClient.Initialize")


def service(client, iid):
    interface = POINTER()
    check(call(client, 14, (POINTER, POINTER), c.byref(iid), c.byref(interface)), "IAudioClient.GetService")
    return interface


def uint_size(client, slot):
    size = DWORD()
    check(call(client, slot, (POINTER,), c.byref(size)), "read buffer size")
    return size.value


def private_renderer(ole):
    enumerator_class = guid("BCDE0395-E52F-467C-8E3D-C4579291692E")
    enumerator_interface = guid("A95664D2-9614-4F35-A746-DE8DB63617E6")
    enumerator, device, client = POINTER(), POINTER(), POINTER()
    create = ole.CoCreateInstance
    create.argtypes = (POINTER, POINTER, DWORD, POINTER, POINTER)
    try:
        check(create(c.byref(enumerator_class), None, 1, c.byref(enumerator_interface), c.byref(enumerator)), "create audio enumerator")
        check(call(enumerator, 4, (c.c_int, c.c_int, POINTER), 0, 1, c.byref(device)), "select render device for this private stream")
        check(call(device, 3, (POINTER, DWORD, POINTER, POINTER), c.byref(IID_CLIENT), 23, None, c.byref(client)), "activate private renderer")
        return client
    finally:
        release(device)
        release(enumerator)


def verify_private_session(volume, expected_muted):
    muted = w.BOOL()
    check(call(volume, 6, (POINTER,), c.byref(muted)), "read private renderer mute")
    if bool(muted.value) != expected_muted:
        raise RuntimeError("The private renderer mute differs from the requested mode. Playback was refused.")
    if not expected_muted:
        level = c.c_float()
        check(call(volume, 4, (POINTER,), c.byref(level)), "read private renderer level")
        if not 0 < level.value <= 1:
            raise RuntimeError("The new private renderer level is not within the expected range.")


def render_child(subthreshold):
    wave_format = FLOAT32 if subthreshold else PCM16
    with com_session() as ole:
        client = private_renderer(ole)
        render = volume = None
        started = False
        try:
            session = Guid.from_buffer_copy(uuid.uuid4().bytes_le)
            initialize(client, RENDER_FLAGS, wave_format, session)
            render, volume = service(client, IID_RENDER), service(client, IID_VOLUME)
            if not subthreshold:
                check(call(volume, 5, (w.BOOL, POINTER), True, c.byref(session)), "mute the private synthetic stream")
            verify_private_session(volume, expected_muted=not subthreshold)
            print("READY SUBTHRESHOLD" if subthreshold else "READY MUTED", flush=True)
            if sys.stdin.readline().strip() != "START":
                return
            size = uint_size(client, 4)
            samples = 0
            deadline = time.monotonic() + (1 if subthreshold else 1.3)
            while time.monotonic() < deadline:
                verify_private_session(volume, expected_muted=not subthreshold)
                padding = uint_size(client, 6)
                available = min(size - padding, RATE // 25)
                if subthreshold:
                    available = min(available, FLOAT_FRAMES - samples)
                    if samples == FLOAT_FRAMES and not padding:
                        break
                if available > 0:
                    data = POINTER()
                    check(call(render, 3, (DWORD, POINTER), available, c.byref(data)), "acquire private render buffer")
                    block = array("f" if subthreshold else "h")
                    for index in range(samples, samples + available):
                        sine = math.sin(2 * math.pi * TONE * index / RATE)
                        if subthreshold:
                            fade = min(1, index / (RATE // 50), (FLOAT_FRAMES - 1 - index) / (RATE // 50))
                            value = FLOAT_PEAK * fade * sine
                        else:
                            value = int(3400 * sine)
                        block.extend((value, value))
                    c.memmove(data, block.tobytes(), available * wave_format.alignment)
                    check(call(render, 4, (DWORD, DWORD), available, 0), "submit synthetic samples")
                    samples += available
                    if not started:
                        check(call(client, 10), "start private renderer")
                        started = True
                time.sleep(.01)
            if subthreshold and samples != FLOAT_FRAMES:
                raise RuntimeError("The renderer did not submit the complete bounded pulse.")
            print(json.dumps({"renderedSamples": samples, "muted": not subthreshold}), flush=True)
        finally:
            if started:
                call(client, 11)
            release(volume)
            release(render)
            release(client)


def activate_pid(pid):
    class Blob(c.Structure):
        _fields_ = [("size", DWORD), ("data", POINTER)]

    class Variant(c.Structure):
        _fields_ = [("tag", w.WORD), ("reserved", w.WORD * 3), ("blob", Blob)]

    class Handler(c.Structure):
        _fields_ = [("table", c.POINTER(POINTER))]

    completion = threading.Event()
    outcome = POINTER()
    result_code = HRESULT()
    # Only this instance's renderer PID and its descendants can contribute.
    parameters = (DWORD * 3)(1, pid, 0)
    props = Variant(65, (w.WORD * 3)(), Blob(c.sizeof(parameters), c.cast(parameters, POINTER)))
    interfaces = [guid(item) for item in ("00000000-0000-0000-C000-000000000046",
                                         "94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90",
                                         "41D949AB-9862-444A-80F6-C261334DA5EB")]
    approved = {c.string_at(c.byref(iid), 16) for iid in interfaces}

    @c.WINFUNCTYPE(HRESULT, POINTER, POINTER, c.POINTER(POINTER))
    def query(this, interface, output):
        if c.string_at(interface, 16) not in approved:
            output[0] = None
            return -2147467262  # E_NOINTERFACE
        output[0] = this
        return 0

    @c.WINFUNCTYPE(w.ULONG, POINTER)
    def keep(_this):
        return 1  # Python owns the handler through the completed operation.

    @c.WINFUNCTYPE(HRESULT, POINTER, POINTER)
    def complete(_this, operation):
        status = call(operation, 3, (POINTER, POINTER), c.byref(result_code), c.byref(outcome))
        if status < 0:
            result_code.value = status
        completion.set()
        return 0

    table = (POINTER * 4)(*(c.cast(item, POINTER) for item in (query, keep, keep, complete)))
    handler = Handler(table)
    operation = POINTER()
    activate = c.WinDLL("mmdevapi").ActivateAudioInterfaceAsync
    activate.argtypes = (w.LPCWSTR, POINTER, POINTER, POINTER, POINTER)
    check(activate("VAD\\Process_Loopback", c.byref(IID_CLIENT), c.byref(props), c.byref(handler), c.byref(operation)), "begin PID-filtered WASAPI loopback")
    if not completion.wait(6):
        # Keep the callback, its parameter backing, and operation alive until
        # the diagnostic process exits rather than freeing a live COM callback.
        _pending.append((operation, handler, query, keep, complete, props, parameters))
        raise RuntimeError("PID-filtered audio activation did not complete in six seconds.")
    try:
        check(result_code.value, "activate PID-filtered WASAPI loopback")
        return outcome
    finally:
        release(operation)


def collect(client, child, subthreshold):
    wave_format = FLOAT32 if subthreshold else PCM16
    initialize(client, LOOPBACK, wave_format)
    capture = service(client, IID_CAPTURE)
    samples = array("f" if subthreshold else "h")
    started = False
    try:
        check(call(client, 10), "start PID-filtered capture")
        started = True
        child.stdin.write("START\n")
        child.stdin.flush()
        limit = time.monotonic() + (1.1 if subthreshold else 1.7)
        while time.monotonic() < limit:
            while uint_size(capture, 5):
                data, size, flags = POINTER(), DWORD(), DWORD()
                check(call(capture, 3, (POINTER, POINTER, POINTER, POINTER, POINTER),
                           c.byref(data), c.byref(size), c.byref(flags), None, None), "read captured child packet")
                try:
                    if size.value:
                        if flags.value & 2:
                            if subthreshold:
                                samples.extend(array("f", [0.0]) * (2 * size.value))
                        else:
                            samples.frombytes(c.string_at(data, size.value * wave_format.alignment))
                finally:
                    check(call(capture, 4, (DWORD,), size.value), "release captured child packet")
            time.sleep(.01)
        return samples[::2]
    finally:
        if started:
            call(client, 11)
        release(capture)


def coefficient(samples, frequency, scale):
    argument = 2 * math.pi * frequency / RATE
    sine = sum(value * math.sin(argument * index) for index, value in enumerate(samples))
    cosine = sum(value * math.cos(argument * index) for index, value in enumerate(samples))
    return 2 * math.hypot(sine, cosine) / (max(len(samples), 1) * scale)


def exercise(subthreshold):
    child_mode = "--subthreshold-renderer" if subthreshold else "--renderer"
    child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), child_mode], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    responses = queue.Queue()

    def receive():
        for line in child.stdout:
            responses.put(line.strip())

    reader = threading.Thread(target=receive, daemon=True)
    reader.start()
    try:
        readiness = responses.get(timeout=7)
        if readiness != ("READY SUBTHRESHOLD" if subthreshold else "READY MUTED"):
            raise RuntimeError(f"Private renderer did not initialize: {readiness}")
        with com_session():
            client = activate_pid(child.pid)
            try:
                signal = collect(client, child, subthreshold)
            finally:
                release(client)
        report = json.loads(responses.get(timeout=3))
        if report["muted"] == subthreshold or not report["renderedSamples"]:
            raise RuntimeError("The child did not emit samples in its requested private session mode.")
        tones = [coefficient(signal, frequency, 1 if subthreshold else 32768) for frequency in (TONE, 593, 877)]
        sigma = 2e-10 if subthreshold else 0.015
        accepted = tones[0] >= sigma and tones[0] > 5 * max(tones[1:])
        report.update(capture="PID include-tree only", nonZeroSamples=sum(value != 0 for value in signal),
                      tones=tones, acceptedTone=accepted)
        if subthreshold:
            report.update(peakSourceDbFS=-160, sourceDurationMs=300, format="float32")
        print(json.dumps(report, ensure_ascii=False))
        return accepted
    finally:
        child.stdin.close()
        try:
            child.wait(2)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(2)
        reader.join(2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--run-muted", action="store_true", help="Use only the generated tone and a private verified-muted session")
    mode.add_argument("--run-subthreshold", action="store_true", help="Opt in to a 300 ms -160 dBFS float pulse in a new private session")
    mode.add_argument("--renderer", action="store_true", help=argparse.SUPPRESS)
    mode.add_argument("--subthreshold-renderer", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("This diagnostic requires Windows.")
    if args.renderer or args.subthreshold_renderer:
        render_child(args.subthreshold_renderer)
    else:
        raise SystemExit(0 if exercise(args.run_subthreshold) else 2)
