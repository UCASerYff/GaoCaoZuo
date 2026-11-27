import hashlib
import io
import os
import time
import zipfile
from pathlib import Path

import pytest

from gaocaozuo.errors import AppError
from gaocaozuo.translation import LocalTranslation, ModelFile, ModelPack, _tokens_in_blocks


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture_pack():
    files = {"model/model.bin": b"model fixture", "sentencepiece.model": b"tokenizer fixture"}
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr("translate-en_zh-1_9/" + name, data)
        archive.writestr("../ignore-unrelated-payload.py", "not extracted")
    body = buffer.getvalue()
    pack = ModelPack("en", "zh", "1.9", len(body), sha(body),
                     tuple(ModelFile(name, len(data), sha(data)) for name, data in files.items()))
    return pack, body, files


class Response(io.BytesIO):
    def __init__(self, body):
        super().__init__(body)
        self.headers = {"Content-Length": str(len(body))}


def complete(translation, job):
    deadline = time.monotonic() + 25
    while job["status"] in {"running", "cancelling"}:
        assert time.monotonic() < deadline, job
        time.sleep(0.02)
        job = translation.job(job["jobId"])
    return job


def test_explicit_approved_download_and_local_translation(tmp_path):
    pack, body, files = fixture_pack()
    urls = []

    def download(url):
        urls.append(url)
        return Response(body)

    def infer(pinned_files, text, target, _stop):
        assert pinned_files == files
        assert text == "local translated text fixture"
        assert target == "zh"
        return "本机验证"

    service = LocalTranslation(tmp_path, packs=[pack], opener=download, infer=infer, runtime=lambda: True, detect=lambda _: "en")
    assert service.catalog()["packs"][0]["status"] == "missing"
    with pytest.raises(AppError, match="确认"):
        service.start_download(pack.pair, "true")
    with pytest.raises(AppError, match="先明确下载"):
        service.start_translation("local translated text fixture", "auto", "zh-CN")
    assert not urls and not service.directory.exists()
    with pytest.raises(AppError, match="列出"):
        service.start_download("https://unrelated.example/file", True)
    downloaded = complete(service, service.start_download(pack.pair, True))
    assert downloaded["status"] == "done" and urls == [pack.url]
    assert sorted(path.relative_to(service.directory / pack.dirname).as_posix()
                  for path in (service.directory / pack.dirname).rglob("*") if path.is_file()) == sorted(files)

    def forbid_network(url):
        raise AssertionError("offline inference tried to download: " + url)

    service.opener = forbid_network
    plan = service.resolve("local translated text fixture", "auto", "zh-Hans")
    assert plan["detected"] and plan["source"] == "en" and plan["packs"][0]["status"] == "installed"
    result = complete(service, service.start_translation("local translated text fixture", "auto", "zh-CN"))
    assert result["status"] == "done"
    assert result["result"]["text"] == "本机验证"
    assert result["result"]["contentSentToCloud"] is False and result["result"]["networkUsed"] is False


def test_corrupt_download_and_installed_file_leave_original(tmp_path):
    pack, body, files = fixture_pack()
    damaged = body[:-1] + bytes([body[-1] ^ 1])
    service = LocalTranslation(tmp_path, packs=[pack], opener=lambda _: Response(damaged), runtime=lambda: True)
    failed = complete(service, service.start_download(pack.pair, True))
    assert failed["status"] == "error" and failed["code"] == "badModel"
    assert list(service.directory.iterdir()) == []
    service.opener = lambda _: Response(body)
    assert complete(service, service.start_download(pack.pair, True))["status"] == "done"
    model = service.directory / pack.dirname / "model" / "model.bin"
    original = files["model/model.bin"]
    changed = bytes([original[0] ^ 1]) + original[1:]
    model.write_bytes(changed)
    failed = complete(service, service.start_translation("sample text", "en", "zh"))
    assert failed["status"] == "error" and failed["code"] == "badModel"
    assert model.read_bytes() == changed


def test_cancel_translation_never_exposes_finished_native_result(tmp_path):
    import threading

    pack, body, _files = fixture_pack()
    entered = threading.Event()
    finish = threading.Event()

    def infer(*_args):
        entered.set()
        assert finish.wait(5)
        return "cancelled output"

    service = LocalTranslation(tmp_path, packs=[pack], opener=lambda _: Response(body), infer=infer, runtime=lambda: True)
    assert complete(service, service.start_download(pack.pair, True))["status"] == "done"
    translating = service.start_translation("sample text", "en", "zh")
    assert entered.wait(5)
    assert service.cancel(translating["jobId"])["status"] == "cancelling"
    finish.set()
    done = complete(service, translating)
    assert done["status"] == "cancelled" and "result" not in done


def test_chunks_preserve_all_sentencepiece_tokens():
    pieces = ["▁one", "two", "▁three"] * 155
    blocks = list(_tokens_in_blocks(pieces))
    assert max(map(len, blocks)) <= 128
    assert [piece for block in blocks for piece in block] == pieces


@pytest.mark.skipif(os.name != "nt", reason="requires a Windows x64 runtime")
def test_native_translation_with_official_local_fixtures(tmp_path):
    archives = os.environ.get("GAO_TRANSLATION_TEST_PACKS")
    if not archives:
        pytest.skip("Set GAO_TRANSLATION_TEST_PACKS to a directory with the two pinned upstream archives.")
    model_dir = Path(archives)

    def local_archive(url):
        filename = url.rsplit("/", 1)[-1]
        path = model_dir / filename
        opened = path.open("rb")
        opened.headers = {"Content-Length": str(path.stat().st_size)}
        return opened

    service = LocalTranslation(tmp_path, opener=local_archive)
    assert service.catalog()["available"]
    for direction in ("zh-en", "en-zh"):
        assert complete(service, service.start_download(direction, True))["status"] == "done"
    service.opener = lambda _url: pytest.fail("network must stay disabled for inference")
    chinese = complete(service, service.start_translation("Hello world.\nThis is an offline translation test.", "auto", "zh"))
    assert chinese["status"] == "done" and chinese["result"]["detected"]
    assert "世界" in chinese["result"]["text"] and "翻译" in chinese["result"]["text"]
    english = complete(service, service.start_translation("你好，世界！\n今天天气很好。", "auto", "en"))
    assert english["status"] == "done" and english["result"]["detected"]
    assert "world" in english["result"]["text"].lower()
