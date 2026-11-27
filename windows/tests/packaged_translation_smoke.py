"""Compare packaged Windows translation against explicitly downloaded official fixture packs."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.request import ProxyHandler, Request, build_opener

from gaocaozuo.translation import LocalTranslation
from gaocaozuo.translation_models import PACKS


class LocalFixture:
    headers = {}

    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.file = self.path.open("rb")
        self.headers = {"Content-Length": str(self.path.stat().st_size)}
        return self

    def read(self, size):
        return self.file.read(size)

    def __exit__(self, *_exc):
        self.file.close()


def await_job(get, job):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        last = get(job["jobId"])
        if last["status"] not in {"running", "cancelling"}:
            assert last["status"] == "done", last
            return last["result"]
        time.sleep(.1)
    raise AssertionError("Translation fixture did not finish.")


def main(executable: Path, files: Path):
    fixture_files = {pack.url: files / pack.url.rsplit("/", 1)[1] for pack in PACKS}
    with tempfile.TemporaryDirectory(prefix="GaoCaoZuo-translation-smoke-") as temp:
        directory = Path(temp)
        data = directory / "data"
        data.mkdir()
        (data / "settings.json").write_text('{"schema":1}', encoding="utf-8")
        downloads = LocalTranslation(data, opener=lambda url: LocalFixture(fixture_files[url]))
        try:
            for pack in PACKS:
                await_job(downloads.job, downloads.start_download(pack.pair, True))
        finally:
            downloads.close()

        stdout = directory / "stdout.txt"
        with stdout.open("wb") as log:
            process = subprocess.Popen([str(executable.resolve()), "--data-dir", str(data), "--no-browser"],
                                       stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            deadline = time.monotonic() + 40
            while process.poll() is None and time.monotonic() < deadline:
                match = re.search(r"^http://127\.0\.0\.1:\d+/$", stdout.read_text(encoding="utf-8", errors="replace"), re.M)
                if match:
                    url = match[0]
                    break
                time.sleep(.1)
            else:
                raise AssertionError("Packaged app did not open its loopback service.")
            client = build_opener(ProxyHandler({}))
            with client.open(url, timeout=10) as page:
                token = re.search(rb'name="gao-token" content="([^"]+)"', page.read())[1].decode("ascii")

            def post(route, body):
                request = Request(url + "api/" + route, data=json.dumps(body).encode(),
                                  headers={"X-Gao-Token": token, "Content-Type": "application/json"})
                with client.open(request, timeout=10) as page:
                    return json.load(page).get("result")

            base = "screenshot/translate"
            catalog = post(base + "/catalog", {})
            assert catalog["available"] and all(pack["status"] == "installed" for pack in catalog["packs"])
            for text, source, target, expected in (
                ("这是一个简单的测试。", "zh", "en", "test"),
                ("This is a simple test.", "en", "zh", "测试"),
            ):
                job = post(base, {"text": text, "source": "auto", "target": target})
                result = await_job(lambda job_id: post(base + "/job", {"jobId": job_id}), job)
                assert result["source"] == source and result["target"] == target
                assert not result["networkUsed"] and expected in result["text"].casefold()
            post("shutdown", {})
            assert process.wait(20) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(15)
    print("Packaged Chinese-English and English-Chinese inference with pinned model archives passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("packages", type=Path)
    arguments = parser.parse_args()
    main(arguments.executable, arguments.packages)
