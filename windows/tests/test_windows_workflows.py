import json
import zipfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaocaozuo.app import App
from gaocaozuo.archive import create_7z, create_zip, extract_archive, inspect_archive
from gaocaozuo.errors import AppError
from gaocaozuo.web import serve


def test_zip_aes_and_7z_volumes_use_normal_archive_path(tmp_path):
    first, second = tmp_path / "甲.txt", tmp_path / "乙.txt"
    first.write_bytes(b"one")
    second.write_bytes(b"two")
    zip_path = create_zip([first], tmp_path / "aes.zip", "档案密码", "aes")
    seven_path = create_7z([first, second], tmp_path / "split.7z", "档案密码", solid=False, split_mb=1)
    assert seven_path.name == "split.7z.001"
    for index, path in enumerate((zip_path, seven_path)):
        members = inspect_archive(path, "档案密码")
        assert members[0]["name"] == first.name
        result = extract_archive(path, tmp_path / f"unpacked-{index}", "档案密码", [first.name])
        assert {p.name for p in result.iterdir()} == {first.name}
        assert (result / first.name).read_bytes() == b"one"


@pytest.mark.parametrize("name", ["folder/file.txt:stream", "NUL.txt", "folder/COM1", "safe. /outside"])
def test_windows_archive_path_restrictions_leave_no_outputs(tmp_path, name):
    path = tmp_path / "invalid.zip"
    with zipfile.ZipFile(path, "w") as handle:
        handle.writestr(name, b"synthetic")
    destination = tmp_path / "out"
    with pytest.raises(AppError) as error:
        extract_archive(path, destination)
    assert error.value.code == "unsafe"
    assert not destination.exists()
    assert not list(tmp_path.glob(".gaocaozuo-extract-*"))


def test_local_web_requires_origin_and_protects_native_dispatch(tmp_path):
    server = serve(App(tmp_path), open_browser=False)
    try:
        with pytest.raises(HTTPError) as error:
            urlopen(Request(server.url, headers={"Host": "unrelated.example"}), timeout=5)
        assert error.value.code == 403
        with pytest.raises(HTTPError) as error:
            urlopen(Request(server.url, headers={"Origin": "https://unrelated.example"}), timeout=5)
        assert error.value.code == 403
        incoming = json.dumps({"id": "window.leftHalf", "payload": {"nativeTarget": {"hwnd": 1}}}).encode()
        with pytest.raises(HTTPError) as error:
            urlopen(Request(server.url + "api/action", data=incoming, headers={"X-Gao-Token": server.token}), timeout=5)
        assert error.value.code == 400
        assert json.load(error.value)["code"] == "invalid"
    finally:
        server.shutdown()
        server.server_close()
