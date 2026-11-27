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
from gaocaozuo.native_win import user
from tray_shell_fixture import ShellTrayFixture, bind_desktop, post


def wait_for(condition, timeout=4):
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() >= deadline:
            raise AssertionError("The tray operation timed out.")
        time.sleep(0.02)


def check_tray(desktop):
    actions = queue.Queue()
    commands = iter((0, 1, 2))
    menus = queue.Queue()

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
        return user(name, result, *args)

    with ShellTrayFixture(desktop) as shell, patch.object(tray_win, "user", bind_test_user):
        icon, owned = tray_win._load_icon()
        assert icon and owned, "The application PNG must supply the source-build HICON."
        user("DestroyIcon", w.BOOL, w.HICON)(icon)
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

            tray.start()  # Starting the same instance again must not announce a second icon.
            assert len(shell.operations) == 2

            shell.taskbar_created()
            wait_for(lambda: len(shell.operations) == 4 and tray.registered)
            recovered, = shell.icons
            assert recovered == first

            shell.taskbar_created(clear_icons=False)
            wait_for(lambda: len(shell.operations) == 7 and tray.registered)
            assert len(shell.icons) == 1 and shell.icons[0].operation == 1

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
        assert tray._window is None and not tray.registered and not shell.icons
        assert not user("IsWindow", w.BOOL, w.HWND)(first.hwnd)
        operations = [message.operation for message in shell.operations]
        assert operations == [0, 4, 0, 4, 0, 1, 4, 3, 2], operations
    return {"shellOperations": operations, "remainingIcons": 0, "brandedIcon": True,
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
