"""Exercise the native message wait with synthetic events on the runtime's own queue."""

import ctypes as c
import ctypes.wintypes as w
import os
import queue
import time
from types import SimpleNamespace

import pytest

from gaocaozuo import runtime_win
from gaocaozuo.desktop_win import WindowIdentity
from gaocaozuo.native_win import user
from gaocaozuo.rules_win import ALT, CTRL
from gaocaozuo.system import FakeSystem, IdlePolicy, SystemGateway


pytestmark = pytest.mark.skipif(os.name != "nt", reason="requires Win32 thread message queues")

_MOUSE = 0x8180
_KEY = 0x8181
_TICK = 0x8182
_HOTKEY = 0x0312


class RuntimeProbe:
    def __init__(self, monkeypatch):
        self.alpha = WindowIdentity(101, 301, 401, 1, "Fixture", "alpha.exe")
        self.beta = WindowIdentity(102, 302, 402, 1, "Fixture", "beta.exe")
        self.target = self.alpha
        self.interactive = True
        self.now = 100.0
        self.modifier_keys = set()
        self.foreground_reads = self.desktop_reads = 0
        self.registrations = {}
        self.hooks = {}
        self.received = 0
        self.results = queue.Queue()
        self.cycles = queue.Queue()
        self.invocations = queue.Queue()
        self.drags = []
        self._peek = user("PeekMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT)
        self._post = user("PostThreadMessageW", w.BOOL, w.DWORD, w.UINT, w.WPARAM, w.LPARAM)
        self._native_wait = runtime_win.wait_for_messages
        monkeypatch.setattr(runtime_win, "user", self.native_api)
        monkeypatch.setattr(runtime_win, "is_input_desktop", self.is_input_desktop)
        monkeypatch.setattr(runtime_win, "wait_for_messages", self.wait)
        monkeypatch.setattr(runtime_win, "time", SimpleNamespace(monotonic=lambda: self.now))
        self.runtime = runtime_win.WindowsRuntime(
            self, SystemGateway(FakeSystem()), IdlePolicy({"enabled": False}),
            lambda action, payload: self.invocations.put((action, payload)),
        )

    def native_api(self, name, result, *arguments):
        substituted = {
            "PeekMessageW": self.peek,
            "GetForegroundWindow": self.foreground,
            "GetAsyncKeyState": lambda vk: -32768 if vk in self.modifier_keys else 0,
            "SetWinEventHook": lambda *_: None,  # Force the missed-notification path.
            "SetWindowsHookExW": self.install_hook,
            "UnhookWindowsHookEx": lambda kind: bool(self.hooks.pop(kind, None)),
            "CallNextHookEx": lambda *_: 0,
            "RegisterHotKey": self.register,
            "UnregisterHotKey": lambda _hwnd, identifier: bool(self.registrations.pop(identifier, None)),
        }
        return substituted[name] if name in substituted else user(name, result, *arguments)

    def foreground(self):
        self.foreground_reads += 1
        return self.target.hwnd

    def is_input_desktop(self):
        self.desktop_reads += 1
        return self.interactive

    def observe_foreground(self):
        return self.target

    def pointer_is_over(self, hwnd, _point):
        return hwnd == self.target.hwnd

    def drag_origin(self, _identity):
        return (10, 20, 100, 200)

    def drag(self, identity, _original, start, point, *, final, snap):
        self.drags.append((identity, start, point, final, snap))

    def install_hook(self, kind, callback, *_):
        self.hooks[kind] = callback
        return kind

    def register(self, _hwnd, identifier, modifiers, vk):
        self.registrations[identifier] = (modifiers & ~0x4000, vk)
        return True

    def wait(self, seconds):
        self.cycles.put(self.received)
        self._native_wait(seconds)

    def peek(self, pointer, hwnd, first, last, remove):
        found = self._peek(pointer, hwnd, first, last, remove)
        if not found or not remove & 1:
            return found
        msg = c.cast(pointer, c.POINTER(w.MSG)).contents
        if msg.message == _MOUSE:
            event = runtime_win._MouseEvent(point=w.POINT(msg.lParam & 0xFFFF, msg.lParam >> 16))
            self.results.put(self.hooks[14](0, msg.wParam, c.addressof(event)))
        elif msg.message == _KEY:
            event = runtime_win._KeyboardEvent(key=msg.wParam, flags=msg.lParam)
            self.results.put(self.hooks[13](0, 0x0100, c.addressof(event)))
        elif msg.message not in {_TICK, _HOTKEY}:
            return found
        self.received += 1
        return found

    def next_cycle(self, expected=0):
        limit = time.monotonic() + 2
        while self.cycles.get(timeout=max(0.01, limit - time.monotonic())) < expected:
            assert time.monotonic() < limit, "Runtime failed to return to its native wait"

    def post(self, message, wparam=0, lparam=0):
        expected = self.received + 1
        assert self._post(self.runtime._message_thread_id, message, wparam, lparam)
        self.next_cycle(expected)

    def mouse(self, message, x=10, y=20):
        self.post(_MOUSE, message, x | (y << 16))
        return self.results.get_nowait()

    def key(self, vk, flags=0):
        self.post(_KEY, vk, flags)
        return self.results.get_nowait()

    def hotkey(self, identifier, mask, vk):
        self.post(_HOTKEY, identifier, mask | (vk << 16))


@pytest.fixture
def probe(monkeypatch):
    instance = RuntimeProbe(monkeypatch)
    yield instance
    instance.runtime.close()
    if instance.runtime._thread is not None:
        assert not instance.runtime._thread.is_alive()
        assert not instance.runtime._worker.is_alive()


def test_native_mouse_wakes_only_refresh_on_a_real_deadline(probe):
    rule = {"id": "mouse", "enabled": True, "actionID": "test.mouse", "trigger": "mouseButton", "mouseButton": 2}
    probe.runtime.configure([rule])
    probe.runtime.start()
    probe.next_cycle()
    before = probe.foreground_reads, probe.desktop_reads
    for i in range(16):
        assert probe.mouse(0x0200, x=10 + i) == 0
    assert (probe.foreground_reads, probe.desktop_reads) == before

    probe.now += 0.26
    probe.post(_TICK)
    assert probe.foreground_reads > before[0] and probe.desktop_reads > before[1]


def test_first_useful_key_refreshes_scope_and_stale_message_cannot_remap(probe):
    shared = {"enabled": True, "shortcut": "Ctrl+Alt+W"}
    probe.runtime.configure([
        {**shared, "id": "a", "actionID": "test.alpha", "application": "alpha.exe"},
        {**shared, "id": "b", "actionID": "test.beta", "application": "beta.exe"},
    ])
    probe.runtime.start()
    probe.next_cycle()
    old_registration, = probe.registrations
    before = probe.foreground_reads, probe.desktop_reads
    probe.target = probe.beta
    assert probe.key(ord("Z")) == 0
    assert probe.key(ord("W"), flags=0x10) == 0  # LLKHF_INJECTED.
    assert (probe.foreground_reads, probe.desktop_reads) == before

    assert probe.key(0xA2) == 0  # VK_LCONTROL, the first physical chord input.
    new_registration, = probe.registrations
    assert new_registration != old_registration
    assert [row["id"] for row in probe.runtime.snapshot()["rules"] if row["status"] == "active"] == ["b"]
    probe.hotkey(old_registration, CTRL | ALT, ord("W"))
    probe.hotkey(new_registration, CTRL | ALT, ord("W"))
    action, payload = probe.invocations.get(timeout=2)
    assert (action, payload["nativeTarget"]) == ("test.beta", probe.beta)
    with pytest.raises(queue.Empty):
        probe.invocations.get(timeout=0.1)


def test_first_useful_mouse_button_can_enter_an_out_of_scope_rule(probe):
    probe.runtime.configure([{
        "id": "mouse", "enabled": True, "actionID": "test.mouse", "trigger": "mouseButton",
        "mouseButton": 2, "application": "beta.exe",
    }])
    probe.runtime.start()
    probe.next_cycle()
    assert probe.runtime.snapshot()["rules"][0]["status"] == "outOfScope"
    probe.target = probe.beta
    assert probe.mouse(0x0207) == 0  # WM_MBUTTONDOWN remains available to the selected app.
    action, payload = probe.invocations.get(timeout=2)
    assert (action, payload["nativeTarget"]) == ("test.mouse", probe.beta)


def test_pending_shortcut_does_not_cross_a_foreground_round_trip(probe):
    probe.runtime.configure([{
        "id": "a", "enabled": True, "actionID": "test.alpha", "shortcut": "Ctrl+W", "application": "alpha.exe",
    }])
    probe.runtime.start()
    probe.next_cycle()
    original, = probe.registrations
    probe.modifier_keys.add(0x11)
    probe.hotkey(original, CTRL, ord("W"))
    probe.target = probe.beta
    assert probe.key(0xA2) == 0 and not probe.registrations
    probe.target = probe.alpha
    assert probe.key(0xA3) == 0  # The right modifier is a new input while the left one remains held.
    current, = probe.registrations
    probe.modifier_keys.clear()
    probe.hotkey(current, CTRL, ord("W"))
    action, payload = probe.invocations.get(timeout=2)
    assert (action, payload["nativeTarget"]) == ("test.alpha", probe.alpha)
    with pytest.raises(queue.Empty):
        probe.invocations.get(timeout=0.1)


def test_native_drag_applies_the_release_even_before_the_next_frame_deadline(probe):
    probe.runtime.configure([], drag=True)
    probe.runtime.start()
    probe.next_cycle()
    probe.modifier_keys.add(0x12)
    assert probe.mouse(0x0201) == 1  # WM_LBUTTONDOWN.
    assert probe.mouse(0x0200, 22, 21) == 0
    assert probe.mouse(0x0202, 42, 25) == 1  # WM_LBUTTONUP.
    assert probe.drags == [(probe.alpha, (10, 20), (42, 25), True, False)]
