import base64
import json
import os
import struct
import subprocess
from pathlib import Path

import pytest
from PIL import Image

from gaocaozuo.errors import AppError
from gaocaozuo.shortcut_icons import ShortcutIcons
from gaocaozuo.shortcut_link import HEADER_SIZE, ICON_ENV, ICON_ENV_SIZE, LINK_CLSID, ShellLink


def _string(value):
    encoded = value.encode("utf-16-le")
    return struct.pack("<H", len(encoded) // 2) + encoded


def _shortcut_fixture(icon=None, environment=False):
    header = bytearray(HEADER_SIZE)
    header[:20] = struct.pack("<I", HEADER_SIZE) + LINK_CLSID
    flags = 0x80 | 4 | 16 | 32 | (0x40 if icon is not None else 0) | (0x4000 if environment else 0)
    struct.pack_into("<I", header, 20, flags)
    struct.pack_into("<iIH", header, 56, -9, 3, 0x0241)
    icon_data = _string(icon) if icon is not None else b""
    tracker = struct.pack("<II", 96, 0xA0000003) + bytes(range(88))
    env = bytearray(ICON_ENV_SIZE)
    struct.pack_into("<II", env, 0, ICON_ENV_SIZE, ICON_ENV)
    env_path = "%SystemRoot%\\System32\\shell32.dll".encode("utf-16-le")
    env[268:268 + len(env_path)] = env_path
    return (bytes(header) + _string("Name") + _string(r"C:\Synthetic") + _string("--flag literal") + icon_data +
            (bytes(env) if environment else b"") + tracker + bytes(4))


@pytest.mark.parametrize("path, env", [(None, False), (r"C:\Synthetic\artist.ico", False), (None, True), (r"C:\fallback.ico", True)])
def test_icon_only_round_trip_preserves_unsigned_blocks_and_other_settings(path, env):
    source = _shortcut_fixture(path, env)
    original = ShellLink(source)
    altered = ShellLink(original.with_icon(Path(r"C:\Icons\Kimi.ico")))
    assert altered.icon_path == r"C:\Icons\Kimi.ico" and altered.icon_index == 0
    assert altered.prefix == original.prefix and altered.blocks == original.blocks
    assert altered.header[60:] == original.header[60:]
    assert altered.restored(original.icon_metadata()) == source


def test_rejects_corrupt_shortcut():
    with pytest.raises(AppError, match="结构"):
        ShellLink(_shortcut_fixture("test")[:-3])
    with pytest.raises(AppError, match="结构"):
        ShellLink(b"not a shortcut")


@pytest.mark.skipif(os.name != "nt", reason="Windows Shell Link and ReplaceFileW")
def test_current_user_shortcut_icon_remains_a_working_shell_link(tmp_path, monkeypatch):
    from gaocaozuo import shortcut_platform_win as platform

    desktop = tmp_path / "Desktop"
    desktop.mkdir()
    start = tmp_path / "Start Menu"
    start.mkdir()
    link = desktop / "ChatGPT.lnk"
    other = start / "Claude.lnk"
    ico = tmp_path / "ChatGPT.ico"
    Image.new("RGBA", (96, 96), (255, 0, 11, 255)).save(ico)
    monkeypatch.setattr(platform, "user_folders", lambda: (("desktop", desktop), ("start", start)))
    payload = r"""
    $shell = New-Object -ComObject WScript.Shell
    $path = [Environment]::GetEnvironmentVariable('GAO_SHORTCUT_TEST_FILE')
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $link.Arguments = '--fixture no launch'
    $link.WorkingDirectory = Split-Path $path
    $link.Description = 'Fixture only'
    $link.Hotkey = 'Ctrl+Alt+N'
    $link.WindowStyle = 3
    $link.Save()
    """
    shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")

    def run(script, path):
        args = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", args],
                                env={**os.environ, "GAO_SHORTCUT_TEST_FILE": str(path)},
                                capture_output=True, check=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
        return result.stdout

    run(payload, link)
    run(payload, other)
    read = r"""
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($env:GAO_SHORTCUT_TEST_FILE)
    @{Target=$link.TargetPath;Arguments=$link.Arguments;Directory=$link.WorkingDirectory;
      Description=$link.Description;Hotkey=$link.Hotkey;Style=$link.WindowStyle;Icon=$link.IconLocation} |
      ConvertTo-Json -Compress
    """
    baseline_shell = json.loads(run(read, link))
    baseline_bytes = link.read_bytes()
    state = ShortcutIcons(tmp_path / "data")
    assert state.dispatch("preview", {"path": str(link)})["preview"].startswith("data:image/png;base64,")
    native = state.dispatch("list", {})
    assert [(row["path"], row["suggested"], row["managed"]) for row in native["items"]] == [(str(link), "chatgpt", False), (str(other), "claude", False)]
    state.dispatch("import", {"role": "chatgpt", "path": str(ico)})
    with pytest.raises(AppError, match="请确认"):
        state.dispatch("apply", {"items": [{"path": str(link), "role": "chatgpt"}]})
    apply = state.dispatch("apply", {"confirm": True, "items": [{"path": str(link), "role": "chatgpt", "variant": "local"}]})
    assert apply["items"][0]["ok"], apply
    after_shell = json.loads(run(read, link))
    assert after_shell.pop("Icon") != baseline_shell.pop("Icon")
    assert after_shell == baseline_shell
    image_path = Path(ShellLink(link.read_bytes()).icon_path)
    assert image_path.read_bytes() == ico.read_bytes()
    receipt = json.loads((tmp_path / "data/ShortcutIcons/state.json").read_text(encoding="utf-8"))["links"]
    assert len(receipt) == 1 and all(set(row) == {"originalHash", "originalIcon", "before", "after"} for row in receipt.values())
    restore = state.dispatch("restore", {"confirm": True, "items": [{"path": str(link)}, {"path": str(other)}]})
    assert restore["items"][0]["ok"] and not restore["items"][1]["ok"]
    assert link.read_bytes() == baseline_bytes

    bundled = tmp_path / "chatgpt.png"
    Image.new("RGBA", (256, 256), (0, 66, 255, 255)).save(bundled)
    monkeypatch.setattr(state, "_bundled_path", lambda role: bundled if role == "chatgpt" else None)
    hd = state.dispatch("apply", {"confirm": True, "items": [{"path": str(link), "role": "chatgpt"}]})
    assert hd["items"][0]["ok"]
    assert Path(ShellLink(link.read_bytes()).icon_path).read_bytes() != ico.read_bytes()
    monkeypatch.setattr(platform, "user_folders", lambda: ())
    persisted = ShortcutIcons(tmp_path / "data").dispatch("list", {})["items"]
    assert len(persisted) == 1 and persisted[0]["path"].casefold() == str(link).casefold() and persisted[0]["managed"]
    conflicting = bytearray(link.read_bytes())
    struct.pack_into("<I", conflicting, 60, 1)
    link.write_bytes(conflicting)
    restore = state.dispatch("restore", {"confirm": True, "items": [{"path": str(link)}]})
    assert not restore["items"][0]["ok"] and link.read_bytes() == conflicting
