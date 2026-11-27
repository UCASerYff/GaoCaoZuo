from copy import deepcopy
from pathlib import Path

import pytest

from gaocaozuo.archive import create_7z, create_zip, extract_archive
from gaocaozuo.archive_editor import ArchiveEditor
from gaocaozuo.errors import AppError
from gaocaozuo.localization import LANGUAGES, language_dictionary
from gaocaozuo.rules_cloud import ROOT_NAME, RuleCloud


@pytest.mark.parametrize("format", ["zip", "7z"])
def test_encrypted_preview_save_copy_and_replace(tmp_path, format):
    original = tmp_path / "before.txt"
    addition = tmp_path / "after.txt"
    original.write_text("first", encoding="utf-8")
    addition.write_text("second", encoding="utf-8")
    path = tmp_path / f"archive.{format}"
    if format == "zip":
        create_zip([original], path, "编辑密码", "aes")
    else:
        create_7z([original], path, "编辑密码")
    raw = path.read_bytes()
    editor = ArchiveEditor()
    preview = editor.preview(path, "编辑密码")
    assert preview["encrypted"] and preview["members"][0]["name"] == original.name
    copy = tmp_path / f"copy.{format}"
    arguments = {"previewID": preview["previewID"], "password": "编辑密码", "add": [str(addition)],
                 "remove": [original.name], "confirm": True}
    with pytest.raises(AppError) as protected:
        editor.save({**arguments, "password": None, "mode": "copy", "destination": str(copy)})
    assert protected.value.code == "password" and not copy.exists()
    editor.save({**arguments, "mode": "copy", "destination": str(copy)})
    assert path.read_bytes() == raw
    extracted = extract_archive(copy, tmp_path / "copy-output", "编辑密码")
    assert [p.name for p in extracted.iterdir()] == [addition.name]
    assert (extracted / addition.name).read_bytes() == addition.read_bytes()

    preview = editor.preview(path, "编辑密码")
    with pytest.raises(AppError) as conflict:
        editor.save({**arguments, "previewID": preview["previewID"], "mode": "copy", "destination": str(copy)})
    assert conflict.value.code == "conflict" and path.read_bytes() == raw
    editor.save({**arguments, "previewID": preview["previewID"], "mode": "replace"})
    assert not list(tmp_path.glob("*.held")) and path.read_bytes() != raw
    assert (extract_archive(path, tmp_path / "updated", "编辑密码") / addition.name).is_file()


def test_changed_archive_never_saves_over_original_or_to_copy(tmp_path):
    item = tmp_path / "item.txt"
    item.write_bytes(b"one")
    archive = create_zip([item], tmp_path / "items.zip")
    editor = ArchiveEditor()
    preview = editor.preview(archive)
    item.write_bytes(b"new source")
    fresh = create_zip([item], tmp_path / "external.zip").read_bytes()
    archive.write_bytes(fresh)
    destination = tmp_path / "copy.zip"
    with pytest.raises(AppError) as failure:
        editor.save({"previewID": preview["previewID"], "confirm": True, "mode": "copy", "destination": str(destination), "removeHidden": True})
    assert failure.value.code == "changed" and archive.read_bytes() == fresh and not destination.exists()


def test_cloud_conflict_requires_current_review_of_remote_action(tmp_path):
    def rule(action_id):
        return {"id": "shortcut-one", "name": "Synthetic rule", "actionID": action_id, "shortcut": "Ctrl+Alt+Q", "enabled": True}

    script = {"id": "local-script", "kind": "script", "script": "local-only-script", "enabled": False}
    a = {"schema": 1, "rules": [rule("window.leftHalf"), script]}
    b = {"schema": 1, "rules": []}

    def service(document):
        def write(value):
            document.clear()
            document.update(deepcopy(value))
        return RuleCloud(lambda: deepcopy(document), write, provider=lambda _path: True)

    first = service(a)
    second = service(b)
    first.configure(str(tmp_path), True)
    second.configure(str(tmp_path), True)
    assert b["rules"][0]["needsReview"] and not b["rules"][0]["enabled"]
    second.approve("shortcut-one", True, True)
    assert b["rules"][0]["enabled"]
    a["rules"][0] = rule("window.topHalf")
    b["rules"][0] = rule("window.rightHalf")
    branch = second.poll(force=True)["heads"][0]
    conflict = first.poll(force=True)
    assert conflict["conflicts"] == ["shortcut-one"]
    assert first.poll(force=True, choice=branch, token="stale")["status"] == "conflict"
    assert a["rules"][0]["actionID"] == "window.topHalf"
    first.poll(force=True, choice=branch, token=conflict["token"])
    assert a["rules"][0]["actionID"] == "window.rightHalf" and a["rules"][0]["needsReview"] and not a["rules"][0]["enabled"]
    assert a["rules"][1] == script
    first.approve("shortcut-one", True, True)
    assert a["rules"][0]["enabled"]
    assert all("local-only-script" not in path.read_text(encoding="utf-8") for path in (tmp_path / ROOT_NAME).glob("*.json"))


def test_localized_navigation_reuses_mac_strings():
    assert len(LANGUAGES) == 10
    assert language_dictionary("zh-Hans") == {}
    assert language_dictionary("en")["工作台"] == "Workbench"
    assert language_dictionary("ja")["文件"] == "ファイル"
    assert language_dictionary("fr")["工作台"] == "Espace de travail"
    assert language_dictionary("it")["工作台"] == "Area di lavoro"
