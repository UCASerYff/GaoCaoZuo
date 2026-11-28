import hashlib
import os
import struct
import zlib
from pathlib import Path

import pytest

from gaocaozuo import mascot_original_pack as original
from gaocaozuo.errors import AppError


def _png_chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def _synthetic_ico(color):
    sizes = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    entries = bytearray(struct.pack("<HHH", 0, 1, len(sizes)))
    frames = bytearray()
    for size in sizes:
        header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
        pixels = (b"\0" + bytes((color, 11, 23, 255)) * size) * size
        png = (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", header)
               + _png_chunk(b"IDAT", zlib.compress(pixels)) + _png_chunk(b"IEND", b""))
        entries.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32,
                                   len(png), 6 + 16 * len(sizes) + len(frames)))
        frames.extend(png)
    return bytes(entries + frames)


@pytest.fixture
def release(tmp_path, monkeypatch):
    ids = ("chatgpt", "claude", "deepseek", "gemini", "grok")
    offsets = (0x3260, 0x56080, 0xB6300, 0x108488, 0x16BD90)
    data = bytearray(2_107_904)
    expected = {}
    for color, (icon_id, offset) in enumerate(zip(ids, offsets), 1):
        ico = _synthetic_ico(color)
        struct.pack_into("<I", data, offset, len(ico))
        data[offset + 4:offset + 4 + len(ico)] = ico
        expected[icon_id] = ico
    path = tmp_path / "AI-Mascot-Icons.exe"

    def write(*, trust):
        path.write_bytes(data)
        if trust:
            monkeypatch.setattr(original, "_RELEASE_SHA256", hashlib.sha256(data).hexdigest())

    write(trust=True)
    return path, data, expected, write


def test_imports_only_the_five_embedded_icons_from_exe_or_folder(release):
    path, _, expected, _ = release
    (path.parent / "unrelated.ico").write_bytes(b"unrelated")
    assert original.load_v1_icons(path) == expected
    assert original.load_v1_icons(path.parent) == expected
    assert (path.parent / "unrelated.ico").read_bytes() == b"unrelated"


@pytest.mark.parametrize("mutation", ["same-size change", "truncated", "oversize"])
def test_rejects_a_different_or_modified_executable(release, mutation):
    path, data, _, write = release
    if mutation == "same-size change":
        data[-1] = 1
    elif mutation == "truncated":
        del data[-1]
    else:
        data.append(0)
    write(trust=False)
    with pytest.raises(AppError, match="未修改"):
        original.load_v1_icons(path)


@pytest.mark.parametrize("position,value", [(0x3260, 0xFFFFFFFF), (0x3268, 1), (0x3276, 0)])
def test_rejects_malformed_embedded_resource_layout(release, position, value):
    path, data, _, write = release
    struct.pack_into("<I", data, position, value)
    write(trust=True)
    with pytest.raises(AppError, match="未修改"):
        original.load_v1_icons(path)


def test_directory_requires_the_exact_exe_and_does_not_scan(release):
    path, _, expected, _ = release
    renamed = path.rename(path.with_name("renamed.exe"))
    assert original.load_v1_icons(renamed) == expected
    with pytest.raises(AppError) as error:
        original.load_v1_icons(path.parent)
    assert error.value.code == "unreadable"


def test_a_link_to_the_original_is_rejected(release):
    path, _, _, _ = release
    link = path.with_name("linked.exe")
    try:
        link.symlink_to(path)
    except OSError as exc:
        if os.name == "nt" and exc.winerror in (5, 1314):
            pytest.skip("Windows does not allow synthetic symbolic links in this session")
        raise
    with pytest.raises(AppError, match="普通文件"):
        original.load_v1_icons(link)


@pytest.mark.skipif(os.name != "nt", reason="Windows directory junctions")
def test_rejects_an_exe_reached_through_a_junction(release):
    from _winapi import CreateJunction

    path, _, _, _ = release
    target = path.parent / "target"
    target.mkdir()
    path.rename(target / path.name)
    link = path.parent / "junction"
    try:
        CreateJunction(str(target), str(link))
    except PermissionError:
        pytest.skip("Windows does not allow synthetic junctions in this session")
    try:
        with pytest.raises(AppError, match="普通文件"):
            original.load_v1_icons(link / path.name)
    finally:
        link.rmdir()


@pytest.mark.skipif(os.name != "nt", reason="Windows UNC paths")
def test_remote_windows_path_is_rejected_before_file_access(monkeypatch):
    def unexpected_read(_):
        pytest.fail("A remote path must be rejected before touching the filesystem")

    monkeypatch.setattr(original, "_local_info", unexpected_read)
    with pytest.raises(AppError, match="本机磁盘"):
        original.load_v1_icons(Path(r"\\invalid.example\share\AI-Mascot-Icons.exe"))
