"""Explicit isolated browser smoke. Requires Chrome or Edge and websocket-client."""

import argparse
import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

import websocket
from PIL import Image, ImageDraw

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
parser.add_argument("--visual-only", action="store_true")
parser.add_argument("--visual-dir", type=pathlib.Path)
options = parser.parse_args()
if not options.browser or not options.browser.is_file():
    parser.error("Specify an installed Chromium executable with --browser.")
if options.visual_only and not options.visual_dir:
    parser.error("--visual-only requires --visual-dir.")
if options.visual_dir:
    options.visual_dir.mkdir(parents=True, exist_ok=True)

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
            def navigate(title):
                js("document.querySelector('.nav-reveal')?.checkVisibility() && document.querySelector('.nav-reveal[aria-expanded=false]').click()")
                click(title, ".nav button")
                wait("document.querySelector('h1')?.textContent === " + json.dumps(title))
            def click_action(title):
                js(f"Array.from(document.querySelectorAll('.action-card')).find(b => b.querySelector('strong')?.textContent === {json.dumps(title)}).querySelector('button').click()")
            def set_theme(theme):
                click("设置")
                wait("!!document.querySelector('dialog select')")
                js("document.querySelector('dialog select').value = " + json.dumps(theme))
                click("保存", "dialog button")
                wait("document.documentElement.dataset.theme === " + json.dumps(theme))
            def screenshot(name):
                if options.visual_dir:
                    response = command("Page.captureScreenshot", {"format": "png"})
                    (options.visual_dir / (name + ".png")).write_bytes(base64.b64decode(response["data"]))
            def viewport(width, height, dpr):
                command("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": dpr, "mobile": False})
            def check_dialog():
                metrics = js("""(() => {
                    const dialog = document.querySelector('dialog[open]');
                    const body = dialog.querySelector('.dialog-body');
                    const footer = dialog.querySelector('.dialog-actions');
                    return [body.scrollWidth - body.clientWidth, dialog.getBoundingClientRect().bottom <= innerHeight,
                            !footer || footer.getBoundingClientRect().bottom <= dialog.getBoundingClientRect().bottom];
                })()""")
                assert metrics == [0, True, True], metrics
            command("Page.enable")
            command("Runtime.enable")
            command("Page.addScriptToEvaluateOnNewDocument", {"source": """
                const nativeFetch = window.fetch.bind(window);
                window.fetch = (url, options) => {
                  if (url === '/api/state' && location.search === '?qa-startup' && !window.qaFailStartup) {
                    return new Promise((_, reject) => {
                      window.qaFailStartup = () => reject(new Error('无法连接到本机工作台。'));
                    });
                  }
                  if (url === '/api/action' && options?.body) {
                    const {id, payload} = JSON.parse(options.body);
                    const windows = [
                      {id: '1001', application: 'Notepad', title: '测试文档 — 记事本', minimized: false, maximized: false},
                      {id: '1002', application: 'Calculator', title: '测试计算器', minimized: true, maximized: false},
                    ];
                    if (id === 'windows.overview' || id === 'system.applicationWindows') {
                      return Promise.resolve(new Response(JSON.stringify({result: {windows}})));
                    }
                    if (id.startsWith('window.') && payload?.apply) {
                      return Promise.reject(new Error('Synthetic window actions remain disabled in this test.'));
                    }
                  }
                  return nativeFetch(url, options);
                };"""})
            command("Page.navigate", {"url": server.url})
            wait("document.querySelector('h1')?.textContent === '工作台'")
            if options.visual_only:
                viewport(1160, 800, 1)
                set_theme("light")
                screenshot("01-workbench-light")
                click("截图与录制", ".nav button")
                screenshot("02-capture-light")
                click("OCR", "[role=tab]")
                screenshot("03-ocr-light")
                click("设置")
                screenshot("04-settings-light")
                js("document.querySelector('dialog[open]').close()")
                click("快捷键与手势", ".nav button")
                click("添加规则")
                screenshot("05-rules-light")
                assert not exceptions, exceptions
                raise SystemExit(0)
            if options.localization_only:
                viewport(900, 680, 1.25)
                intro = "快捷键、鼠标手势与规则"
                template = "新增文件与压缩包成员重名：{name}"
                fixture = r"C:\Fixture folder\draft {text}.zip"
                for language in LANGUAGES:
                    pref = json.dumps({"language": language})
                    result = command("Runtime.evaluate", {"expression": f"api('/api/settings', {pref})", "awaitPromise": True})
                    assert not result.get("exceptionDetails"), result
                    js("window.previousDocument = true")
                    command("Page.reload")
                    expect = language_dictionary(language)
                    expected = json.dumps(expect.get(intro, intro))
                    wait(f"!window.previousDocument && typeof trError === 'function' && document.documentElement.lang === {json.dumps(language)} && document.querySelector('.destination:last-child small')?.textContent === {expected}")
                    message = template.format(name=fixture)
                    translated = expect.get(template, template).format(name=fixture)
                    assert js(f"trError({json.dumps(message)})") == translated, language
                assert not exceptions, exceptions
                print("All 10 workbench locales render long prompts and preserve path placeholders at 125%.")
                raise SystemExit(0)
            viewport(640, 600, 1.5)
            command("Page.navigate", {"url": server.url + "?qa-startup"})
            wait("!!window.qaFailStartup && !!document.querySelector('.startup-state [role=status], .startup-state[role=status]')")
            screenshot("startup-loading-light-150")
            js("window.qaFailStartup()")
            wait("document.querySelector('.startup-state[role=alert] h1')?.textContent === '无法打开工作台'")
            screenshot("startup-error-light-150")
            click("重试")
            wait("document.querySelector('h1')?.textContent === '工作台'")
            assert js("document.querySelectorAll('.nav button').length") == 12
            assert js("document.querySelectorAll('.destination').length") == 6
            set_theme("light")
            for theme in ["light", "dark"]:
                if theme == "dark": set_theme(theme)
                viewport(1160, 800, 1)
                screenshot(f"workbench-{theme}")
                for name in ["截图与录制", "剪贴板", "文件", "压缩与解压", "实用工具", "窗口", "桌面总览", "锁屏策略", "快捷键与手势", "组合操作", "恢复记录", "工作台"]:
                    navigate(name)
                    for width, height, dpr in [(1160, 800, 1), (900, 640, 1.25), (640, 660, 1.5), (428, 570, 1.5)]:
                        viewport(width, height, dpr)
                        pane = js("(() => {const body = document.querySelector('.body'); return [body.clientWidth, body.scrollWidth, devicePixelRatio]})()")
                        assert pane[0] == pane[1] and pane[2] == dpr, (name, theme, width, pane)
                    if name == "截图与录制": screenshot(f"capture-{theme}-narrow-150")
                    if name == "剪贴板": screenshot(f"clipboard-{theme}-narrow-150")
                    if name == "窗口":
                        wait("document.querySelector('.window-target select')?.options.length === 3")
                        assert js("""(() => {
                            const a = document.querySelector('.window-target select').getBoundingClientRect();
                            const b = document.querySelector('.window-target button').getBoundingClientRect();
                            return a.right <= b.left || a.bottom <= b.top;
                        })()""")
                        screenshot(f"window-control-{theme}-narrow-150")
                    if name == "桌面总览" and theme == "dark":
                        wait("document.querySelector('.body')?.innerText.includes('测试文档 — 记事本')")
                        click("关闭…", ".body .list-row button")
                        wait("document.querySelector('dialog[open] h2')?.textContent === '关闭所选窗口？'")
                        check_dialog()
                        assert js("!!document.querySelector('dialog[open] .dialog-actions button.danger')")
                        screenshot("window-close-confirm-dark-narrow-150")
                        click("取消", "dialog[open] button")
                screenshot(f"workbench-{theme}-narrow-150")
                js("(() => {const toggle = document.querySelector('.nav-reveal'); toggle.focus(); toggle.click()})()")
                wait("document.querySelector('.nav-reveal').getAttribute('aria-expanded') === 'true'")
                screenshot(f"navigation-{theme}-narrow-150")
                command("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Escape", "code": "Escape"})
                wait("document.querySelector('.nav-reveal').getAttribute('aria-expanded') === 'false'")
                click("设置")
                wait("!!document.querySelector('.settings-system summary')")
                check_dialog()
                screenshot(f"settings-{theme}-narrow-150")
                js("document.querySelector('.settings-system summary').click()")
                wait("!!document.querySelector('.settings-system[open] .settings-permission')")
                check_dialog()
                js("document.querySelector('dialog[open]').close()")
                viewport(1160, 800, 1)
                print(theme + " all 12 sections at 1160, 900 at 125%, and 640 and 428 at 150%")
            command("Input.dispatchKeyEvent", {"type": "keyDown", "modifiers": 2, "key": "k", "code": "KeyK", "windowsVirtualKeyCode": 75})
            wait("document.querySelector('dialog h2')?.textContent === '操作面板'")
            assert js("document.activeElement.matches('dialog input[type=search]')")
            click("压缩与解压", ".action-categories button")
            js("(() => {const x = document.querySelector('dialog input'); x.value = '压缩'; x.dispatchEvent(new Event('input'))})()")
            wait("Array.from(document.querySelectorAll('dialog .action-card')).some(x => x.textContent.includes('ZIP'))")
            assert js("document.querySelector('.action-categories [aria-pressed=true]').textContent === '压缩与解压'")
            screenshot("command-library-dark")
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
            viewport(428, 570, 1.5)
            check_dialog()
            screenshot("archive-preview-dark-narrow-150")
            viewport(1160, 800, 1)
            js("document.querySelector('dialog[open]').close()")
            import zipfile
            removed_member = "合成待移除附件.txt"
            with zipfile.ZipFile(archive, "a") as original:
                original.writestr(removed_member, "remove only these synthetic bytes")
            original_bytes = archive.read_bytes()
            click_action("预览压缩包")
            wait("document.querySelectorAll('dialog[open] .archive-member').length === 2")
            assert js("document.querySelector('dialog[open] .dialog-actions .primary').disabled")
            js("Array.from(document.querySelectorAll('dialog[open] .archive-member label')).find(x => x.textContent === " +
               json.dumps(removed_member) + ").querySelector('input').click()")
            assert js("!document.querySelector('dialog[open] .dialog-actions .primary').disabled")
            click("编辑压缩包…", "dialog[open] button")
            wait("document.querySelector('dialog[open] .archive-removals li')?.textContent === " + json.dumps(removed_member))
            viewport(428, 570, 1.5)
            check_dialog()
            screenshot("archive-editor-dark-narrow-150")
            click("另存新副本…", "dialog[open] button")
            js("document.querySelector('dialog[open] input').value = " + json.dumps(str(path)))
            click("继续", "dialog[open] button")
            wait("document.querySelector('dialog[open] h2')?.textContent === '新压缩包名称'")
            js("document.querySelector('dialog[open] input').value = 'bad/name.zip'")
            click("保存", "dialog[open] button")
            wait("document.querySelector('dialog[open] .modal-error:not([hidden])')?.textContent === '请输入有效文件名称。'")
            check_dialog()
            screenshot("archive-invalid-name-dark-narrow-150")
            js("document.querySelector('dialog[open] input').value = 'hello-edited.zip'")
            click("保存", "dialog[open] button")
            wait("!document.querySelector('dialog[open]') && document.querySelector('footer').innerText.includes('hello-edited.zip')")
            with zipfile.ZipFile(path / "hello-edited.zip") as saved:
                assert saved.namelist() == ["hello.txt"] and saved.read("hello.txt") == sample_text.read_bytes()
            assert archive.read_bytes() == original_bytes
            viewport(1160, 800, 1)
            click_action("直接解压")
            wait("document.querySelector('dialog[open] h2')?.textContent === '解压结果'")
            assert (path / "hello" / "hello.txt").read_text() == sample_text.read_text()
            js("document.querySelector('dialog[open]').close()")
            image = path / "synthetic.png"
            fixture = Image.new("RGB", (320, 180), "#dce9f9")
            draw = ImageDraw.Draw(fixture)
            draw.rectangle((28, 25, 292, 154), fill="#ffffff", outline="#245a99", width=2)
            draw.text((48, 100), "Synthetic screenshot fixture", fill="#172537")
            draw.rectangle((53, 48, 235, 81), fill="#245a99")
            fixture.save(image)
            app.activate({"paths": [str(image)]})
            wait("document.querySelector('h1')?.textContent === '文件'")
            click("截图与录制", ".nav button")
            click("打开图像…")
            wait("document.querySelector('canvas')?.width === 320")
            click("向右旋转")
            wait("document.querySelector('canvas')?.width === 180")
            screenshot("annotation-result-dark")
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
            viewport(428, 570, 1.5)
            check_dialog()
            screenshot("rule-editor-dark-narrow-150")
            click("保存", "dialog button")
            wait("[...document.querySelectorAll('.rule-key-combination kbd')].map(key => key.textContent).join('+') === 'Ctrl+Alt+W'")
            assert app.rules()[0]["shortcut"] == "Ctrl+Alt+W"
            viewport(1160, 800, 1)
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
