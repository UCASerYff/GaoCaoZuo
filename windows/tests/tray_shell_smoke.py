"""Exercise the production tray against real Shell32 calls on an unswitched desktop."""

import ctypes as c
import ctypes.wintypes as w
import json
import queue
import sys
import time
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from gaocaozuo import tray_win
from gaocaozuo.native_win import bind, user
from tray_shell_fixture import ShellTrayFixture, bind_desktop, post


def wait_for(condition, timeout=4):
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() >= deadline:
            raise AssertionError("The tray operation timed out.")
        time.sleep(0.02)


def icon_dimensions(handle):
    class IconInfo(c.Structure):
        _fields_ = [("is_icon", w.BOOL), ("hot_x", w.DWORD), ("hot_y", w.DWORD),
                    ("mask", w.HBITMAP), ("color", w.HBITMAP)]

    class Bitmap(c.Structure):
        _fields_ = [("kind", w.LONG), ("width", w.LONG), ("height", w.LONG), ("width_bytes", w.LONG),
                    ("planes", w.WORD), ("bits_per_pixel", w.WORD), ("bits", w.LPVOID)]

    info = IconInfo()
    assert user("GetIconInfo", w.BOOL, w.HICON, c.POINTER(IconInfo))(handle, c.byref(info))
    delete = bind("gdi32", "DeleteObject", w.BOOL, w.HGDIOBJ)
    try:
        assert info.is_icon and info.color
        bitmap = Bitmap()
        assert bind("gdi32", "GetObjectW", c.c_int, w.HGDIOBJ, c.c_int, w.LPVOID)(
            info.color, c.sizeof(bitmap), c.byref(bitmap)
        ) == c.sizeof(bitmap)
        return bitmap.width, bitmap.height
    finally:
        if info.color:
            delete(info.color)
        if info.mask:
            delete(info.mask)


def check_tray(desktop):
    actions = queue.Queue()
    commands = iter((0, 1, 2))
    menus = queue.Queue()
    destroyed = queue.Queue()
    dpi = 96

    class PrivateTray(tray_win.WindowsTray):
        def _loop(self):
            bind_desktop(desktop)
            super()._loop()

    def select_menu_item(menu, flags, _x, _y, _owner, _parameters):
        get_label = user("GetMenuStringW", c.c_int, w.HMENU, w.UINT, w.LPWSTR, c.c_int, w.UINT)
        labels = []
        for item in (1, 2):
            label = c.create_unicode_buffer(128)
            get_label(menu, item, label, len(label), 0)
            labels.append(label.value)
        default_id = user("GetMenuDefaultItem", w.UINT, w.HMENU, w.UINT, w.UINT)(menu, 0, 0)
        menus.put((labels, default_id, flags))
        return next(commands)

    def bind_test_user(name, result, *args):
        # Build a native HMENU, but choose its result without switching desktops or injecting input.
        if name == "TrackPopupMenuEx":
            return select_menu_item
        if name == "GetDpiForWindow":
            def test_dpi(hwnd):
                assert hwnd == shell.hwnd
                return dpi
            return test_dpi
        if name == "GetAwarenessFromDpiAwarenessContext":
            return lambda _context: 2  # Simulate Explorer having per-monitor awareness.
        if name == "DestroyIcon":
            def destroy_icon(handle):
                released = user(name, result, *args)(handle)
                if released:
                    destroyed.put(handle)
                return released
            return destroy_icon
        return user(name, result, *args)

    with ShellTrayFixture(desktop) as shell, patch.object(tray_win, "user", bind_test_user):
        tray = PrivateTray(lambda: actions.put("open"), lambda: actions.put("exit"))
        tray.configure(True)
        tray.start()
        try:
            assert tray.ready.wait(4)
            wait_for(lambda: tray.registered and len(shell.operations) == 2)
            first, = shell.icons
            assert first.icon and first.tooltip == "搞操作"
            assert first.hwnd == tray._window
            assert not user("IsWindowVisible", w.BOOL, w.HWND)(first.hwnd)
            assert icon_dimensions(first.icon) == (16, 16)

            tray.start()  # Starting the same instance again must not announce a second icon.
            assert len(shell.operations) == 2

            expected_sizes = {96: 16, 120: 20, 144: 24, 168: 28, 192: 32}
            counts = 2
            current = first
            send = user("SendMessageTimeoutW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
                        w.UINT, w.UINT, c.POINTER(c.c_size_t))
            suggested = w.RECT()  # The tray's hidden receiver has no visible bounds.
            for dpi in (120, 144, 168, 192):
                assert send(first.hwnd, 0x02E0, dpi | (dpi << 16), c.addressof(suggested), 2, 2000, None)
                counts += 1
                wait_for(lambda: len(shell.operations) == counts)
                previous = current
                current, = shell.icons
                pixels = expected_sizes[dpi]
                assert icon_dimensions(current.icon) == (pixels, pixels)
                assert (current.hwnd, current.icon_id, current.operation) == (first.hwnd, first.icon_id, 1)
                assert destroyed.get(timeout=4) == previous.icon

            dpi = 120
            shell.taskbar_created()
            counts += 2
            wait_for(lambda: len(shell.operations) == counts and tray.registered)
            recovered, = shell.icons
            assert (recovered.hwnd, recovered.icon_id, recovered.operation) == (first.hwnd, first.icon_id, 0)
            assert icon_dimensions(recovered.icon) == (20, 20)
            assert destroyed.get(timeout=4) == current.icon

            dpi = 168
            shell.taskbar_created(clear_icons=False)
            counts += 3
            wait_for(lambda: len(shell.operations) == counts and tray.registered)
            current, = shell.icons
            assert (current.hwnd, current.icon_id, current.operation) == (first.hwnd, first.icon_id, 1)
            assert icon_dimensions(current.icon) == (28, 28)
            assert destroyed.get(timeout=4) == recovered.icon

            coordinate = (12 << 16) | 13
            post(first.hwnd, first.callback, coordinate, (2 << 16) | 0x0400)  # unrelated icon
            post(first.hwnd, first.callback, coordinate, (1 << 16) | 0x0400)  # NIN_SELECT
            post(first.hwnd, first.callback, coordinate, (1 << 16) | 0x0401)  # NIN_KEYSELECT
            assert actions.get(timeout=4) == actions.get(timeout=4) == "open"
            assert actions.empty()

            for _ in range(3):
                post(first.hwnd, first.callback, coordinate, (1 << 16) | 0x007B)  # WM_CONTEXTMENU
                assert menus.get(timeout=4) == (["打开 搞操作", "退出"], 1, 0x0182)
            assert actions.get(timeout=4) == "open"
            assert actions.get(timeout=4) == "exit"
            assert actions.empty()
        finally:
            tray.close()
        assert destroyed.get(timeout=4) == current.icon
        assert destroyed.empty()
        assert tray._window is None and not tray.registered and not shell.icons
        assert not user("IsWindow", w.BOOL, w.HWND)(first.hwnd)
        operations = [message.operation for message in shell.operations]
        assert operations == [0, 4, 1, 1, 1, 1, 0, 4, 0, 1, 4, 3, 2], operations
    return {"shellOperations": operations, "remainingIcons": 0, "brandedIcon": True,
            "iconPixelsBySimulatedDpi": expected_sizes,
            "mouseOpen": True, "keyboardOpen": True, "menuCancelOpenExit": True}


def main():
    create = user("CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID)
    desktop = create("GaoOperationShellTest-" + uuid.uuid4().hex, None, None, 0, 0x000F01FF, None)
    if not desktop:
        raise c.WinError(c.get_last_error())
    try:
        print(json.dumps(check_tray(desktop), ensure_ascii=False))
    finally:
        user("CloseDesktop", w.BOOL, w.HANDLE)(desktop)


if __name__ == "__main__":
    main()
