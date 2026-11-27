"""Explicit isolated browser smoke. Requires Chrome or Edge and websocket-client."""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

import websocket
from PIL import Image

repo = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repo / "windows" / "src"))
from gaocaozuo.app import App
from gaocaozuo.localization import LANGUAGES, language_dictionary
from gaocaozuo.shell_win import browser_path
from gaocaozuo.web import serve


class PackagedApp:
    def __init__(self, executable, path):
        log = path / "packaged.stdout"
        with log.open("wb") as output:
            self.process = subprocess.Popen(
                [str(executable.resolve()), "--no-browser", "--data-dir", str(path / "data"), "--port", "0"],
                creationflags=subprocess.CREATE_NO_WINDOW, stdout=output, stderr=subprocess.STDOUT,
            )
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and self.process.poll() is None:
                url = re.search(r"^http://127\.0\.0\.1:\d+/$", log.read_text(encoding="utf-8", errors="replace"), re.M)
                if url:
                    self.url = url[0]
                    with self.opener.open(self.url, timeout=5) as page:
                        self.token = re.search(rb'name="gao-token" content="([^"]+)"', page.read())[1].decode("ascii")
                    self.post("settings/create", {})
                    self.post("settings", {"language": "zh-Hans"})
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Packaged app did not start its loopback listener.")
        except BaseException:
            self.server_close()
            raise

    def post(self, path, value):
        request = urllib.request.Request(self.url + "api/" + path, data=json.dumps(value).encode(),
                                         headers={"X-Gao-Token": self.token, "Content-Type": "application/json"})
        with self.opener.open(request, timeout=10) as response:
            return json.load(response)

    def activate(self, values):
        return self.post("activate", values)["result"]

    def rules(self):
        return self.post("rules/list", {})["result"]["rules"]

    def shutdown(self):
        if self.process.poll() is None:
            self.post("shutdown", {})

    def server_close(self):
        try:
            self.process.wait(8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--browser", type=pathlib.Path, default=browser_path())
parser.add_argument("--packaged-cli", type=pathlib.Path)
parser.add_argument("--localization-only", action="store_true")
options = parser.parse_args()
if not options.browser or not options.browser.is_file():
    parser.error("Specify an installed Chromium executable with --browser.")

with tempfile.TemporaryDirectory(prefix=".ui-qa-", dir=repo) as temp:
    path = pathlib.Path(temp)
    if options.packaged_cli:
        app = server = PackagedApp(options.packaged_cli, path)
    else:
        app = App(path / "data")
        app.create_settings()
        app.update_settings({"language": "zh-Hans"})
        server = serve(app, open_browser=False)
    profile = path / "profile"
    with tempfile.TemporaryFile() as log:
        browser = subprocess.Popen([str(options.browser), "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-breakpad", "--disable-crash-reporter", "--enable-logging=stderr",
            "--remote-debugging-port=0", f"--user-data-dir={profile}", "about:blank"], creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=log)
        cdp = None
        try:
            endpoint = profile / "DevToolsActivePort"
            for _ in range(75):
                if endpoint.exists(): break
                if browser.poll() is not None: break
                time.sleep(.08)
            if not endpoint.exists():
                log.seek(0)
                print(log.read().decode("utf-8", errors="backslashreplace"))
                raise AssertionError(f"no headless Chromium CDP endpoint, exit={browser.poll()}")
            port = endpoint.read_text().splitlines()[0]
            with urllib.request.urlopen("http://127.0.0.1:" + port + "/json") as handle:
                target = next(item for item in json.load(handle) if item["type"] == "page")
            cdp = websocket.create_connection(target["webSocketDebuggerUrl"], timeout=8, suppress_origin=True)
            seq = 0
            exceptions = []
            def command(method, params=None):
                global seq
                seq += 1
                cdp.send(json.dumps({"id": seq, "method": method, "params": params or {}}))
                while True:
                    result = json.loads(cdp.recv())
                    if result.get("id") == seq:
                        if "error" in result: raise RuntimeError(result)
                        return result["result"]
                    if result.get("method") == "Runtime.exceptionThrown": exceptions.append(result)
            def js(expr):
                out = command("Runtime.evaluate", {"expression": expr, "returnByValue": True})
                if out.get("exceptionDetails"): raise RuntimeError(out)
                return out["result"].get("value")
            def wait(predicate):
                for _ in range(85):
                    if js(predicate): return
                    time.sleep(.06)
                raise AssertionError(f"{predicate}\n{js('document.body.innerText')}")
            def click(title, scope="button"):
                js(f"Array.from(document.querySelectorAll({json.dumps(scope)})).find(b => b.textContent.trim() === {json.dumps(title)}).click()")
            def click_action(title):
                js(f"Array.from(document.querySelectorAll('.action-card')).find(b => b.querySelector('strong')?.textContent === {json.dumps(title)}).querySelector('button').click()")
            def set_theme(theme):
                click("设置")
                wait("!!document.querySelector('dialog select')")
                js("document.querySelector('dialog select').value = " + json.dumps(theme))
                click("保存", "dialog button")
                wait("document.documentElement.dataset.theme === " + json.dumps(theme))
            command("Page.enable")
            command("Runtime.enable")
            command("Page.navigate", {"url": server.url})
            wait("document.querySelector('h1')?.textContent === '工作台'")
            if options.localization_only:
                command("Emulation.setDeviceMetricsOverride", {"width": 900, "height": 680, "deviceScaleFactor": 1.25, "mobile": False})
                intro = "处理文件、整理窗口、记录灵感。\n从这里开始，少点几下。"
                template = "新增文件与压缩包成员重名：{name}"
                fixture = r"C:\Fixture folder\draft {text}.zip"
                for language in LANGUAGES:
                    pref = json.dumps({"language": language})
                    result = command("Runtime.evaluate", {"expression": f"api('/api/settings', {pref})", "awaitPromise": True})
                    assert not result.get("exceptionDetails"), result
                    command("Page.reload")
                    expect = language_dictionary(language)
                    expected = json.dumps(expect.get(intro, intro))
                    wait(f"document.documentElement.lang === {json.dumps(language)} && document.querySelector('.hero p')?.textContent === {expected}")
                    message = template.format(name=fixture)
                    translated = expect.get(template, template).format(name=fixture)
                    assert js(f"trError({json.dumps(message)})") == translated, language
                assert not exceptions, exceptions
                print("All 10 workbench locales render long prompts and preserve path placeholders at 125%.")
                raise SystemExit(0)
            assert js("document.querySelectorAll('.nav button').length") == 12
            assert js("document.querySelectorAll('.destination').length") == 4
            set_theme("light")
            for theme in ["light", "dark"]:
                if theme == "dark": set_theme(theme)
                for name in ["截图与录制", "剪贴板", "文件", "压缩与解压", "实用工具", "窗口", "桌面总览", "锁屏策略", "快捷键与手势", "组合操作", "恢复记录", "工作台"]:
                    click(name, ".nav button")
                    wait("document.querySelector('h1')?.textContent === " + json.dumps(name))
                    for width, height, dpr in [(1160, 800, 1), (900, 640, 1.25), (640, 700, 1.5)]:
                        command("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": dpr, "mobile": False})
                        pane = js("(() => {const body = document.querySelector('.body'); return [body.clientWidth, body.scrollWidth, devicePixelRatio]})()")
                        assert pane[0] == pane[1] and pane[2] == dpr, (name, theme, width, pane)
                print(theme + " all 12 sections at 1160, 900 125% and 640 150%")
                command("Emulation.setDeviceMetricsOverride", {"width": 1160, "height": 800, "deviceScaleFactor": 1, "mobile": False})
            click("打开操作面板")
            wait("document.querySelector('dialog h2')?.textContent === '操作面板'")
            js("(() => {const x = document.querySelector('dialog input'); x.value = '压缩'; x.dispatchEvent(new Event('input'))})()")
            wait("Array.from(document.querySelectorAll('dialog .action-card')).some(x => x.textContent.includes('ZIP'))")
            js("document.querySelector('dialog').close()")
            click("截图与录制", ".nav button")
            for name in ["标注", "OCR", "录屏与录音", "翻译", "历史与交接", "截图"]:
                click(name, "[role=tab]")
                wait("document.querySelector('[role=tab][aria-selected=true]').textContent === " + json.dumps(name))
            sample_text = path / "hello.txt"
            sample_text.write_text("isolated archive fixture", encoding="utf-8")
            app.activate({"paths": [str(sample_text)]})
            wait("document.querySelector('h1')?.textContent === '文件'")
            click("压缩与解压", ".nav button")
            click_action("压缩为 ZIP")
            archive = path / "hello.zip"
            wait("document.querySelector('footer').innerText.includes('hello.zip')")
            assert archive.is_file()
            app.activate({"paths": [str(archive)]})
            wait("document.querySelector('h1')?.textContent === '文件'")
            click("压缩与解压", ".nav button")
            click_action("预览压缩包")
            wait("document.querySelector('dialog[open]')?.innerText.includes('hello.txt')")
            js("document.querySelector('dialog[open]').close()")
            click_action("直接解压")
            wait("document.querySelector('dialog[open] h2')?.textContent === '解压结果'")
            assert (path / "hello" / "hello.txt").read_text() == sample_text.read_text()
            js("document.querySelector('dialog[open]').close()")
            image = path / "synthetic.png"
            Image.new("RGB", (320, 180), "white").save(image)
            app.activate({"paths": [str(image)]})
            wait("document.querySelector('h1')?.textContent === '文件'")
            click("截图与录制", ".nav button")
            click("打开图像…")
            wait("document.querySelector('canvas')?.width === 320")
            click("向右旋转")
            wait("document.querySelector('canvas')?.width === 180")
            click("另存图像…")
            wait("document.querySelector('dialog[open] h2')?.textContent === '另存图像'")
            js("document.querySelector('dialog[open] input').value = " + json.dumps(str(path)))
            click("保存", "dialog button")
            wait("document.querySelector('footer').innerText.includes('已保存')")
            assert len([*path.glob("*.png")]) == 2
            click("快捷键与手势", ".nav button")
            click("添加规则")
            wait("document.querySelector('dialog[open] h2')?.textContent === '编辑输入规则'")
            js("document.querySelector('dialog input[placeholder=\"Ctrl+Alt+W\"]').value = 'Ctrl+Alt+W'")
            click("保存", "dialog button")
            wait("document.body.innerText.includes('Ctrl+Alt+W')")
            assert app.rules()[0]["shortcut"] == "Ctrl+Alt+W"
            click("设置")
            wait("document.querySelectorAll('dialog select')[1]?.options.length === 11")
            js("document.querySelectorAll('dialog select')[1].value = 'en'")
            click("保存", "dialog button")
            wait("document.documentElement.lang === 'en'")
            click("Workbench", ".nav button")
            wait("document.querySelector('h1')?.textContent === 'Workbench'")
            assert not exceptions, exceptions
            print("Theme and interface-language persistence, action search, six screenshot tabs, Explorer handoff, ZIP preview/extraction, image open/rotate/save, and rule persistence passed.")
        finally:
            server.shutdown()
            server.server_close()
            if cdp is not None:
                try: command("Browser.close")
                except Exception: pass
                cdp.close()
            try:
                browser.wait(timeout=8)
            except subprocess.TimeoutExpired:
                browser.terminate()
                browser.wait(timeout=8)
