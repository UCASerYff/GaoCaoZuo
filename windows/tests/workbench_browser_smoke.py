"""Explicit isolated browser smoke. Requires Chrome or Edge and websocket-client."""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

import websocket
from PIL import Image, ImageDraw, ImageFont

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


def make_ocr_fixture(scratch, return_root, source, ticket=True):
    request_id = str(uuid.uuid4())
    package = scratch / (request_id + ".gaoaction")
    payload = package / "payload"
    payload.mkdir(parents=True)
    image = Image.new("RGB", (750, 170), "white")
    font_path = pathlib.Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts" / "segoeui.ttf"
    ImageDraw.Draw(image).text((26, 35), "Test 12345", fill="black", font=ImageFont.truetype(str(font_path), 76))
    sample = payload / "synthetic.png"
    image.save(sample)
    content = sample.read_bytes()
    now = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(seconds=1)
    manifest = {"schemaVersion": 1, "kind": "request", "requestID": request_id, "action": "ocr.files",
                "sourceBundleID": source, "targetBundleID": "com.gaoseries.GaoCaoZuo",
                "createdAt": now.isoformat().replace("+00:00", "Z"),
                "expiresAt": (now + timedelta(seconds=115)).isoformat().replace("+00:00", "Z"),
                "parameters": {"outputs": ["text"]}, "references": [],
                "nonce": base64.b64encode(os.urandom(32)).decode("ascii"),
                "items": [{"id": "synthetic-png", "uti": "public.png", "relativePath": sample.name,
                           "byteCount": len(content), "sha256": hashlib.sha256(content).hexdigest()}]}
    raw = json.dumps(manifest, indent=2).encode("utf-8")
    (package / "manifest.json").write_bytes(raw)
    slot = return_root / request_id
    slot.mkdir(parents=True)
    return_ticket = {key: manifest[key] for key in ("schemaVersion", "requestID", "action", "sourceBundleID", "targetBundleID", "expiresAt")}
    return_ticket["requestManifestSHA256"] = hashlib.sha256(raw).hexdigest()
    if ticket:
        write_return_ticket(slot, return_ticket)
    return package, slot, return_ticket


def write_return_ticket(slot, ticket):
    temporary = slot / "request.tmp"
    temporary.write_bytes(json.dumps(ticket, ensure_ascii=False).encode("utf-8"))
    temporary.rename(slot / "request.json")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--browser", type=pathlib.Path, default=browser_path())
parser.add_argument("--packaged-cli", type=pathlib.Path)
parser.add_argument("--localization-only", action="store_true")
parser.add_argument("--visual-only", action="store_true")
parser.add_argument("--visual-dir", type=pathlib.Path)
parser.add_argument("--preview-ocr", action="store_true", help="Test rule previews and two native OCR return flows with synthetic data.")
options = parser.parse_args()
if not options.browser or not options.browser.is_file():
    parser.error("Specify an installed Chromium executable with --browser.")
if options.visual_only and not options.visual_dir:
    parser.error("--visual-only requires --visual-dir.")
if options.visual_dir:
    options.visual_dir.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix=".ui-qa-", dir=repo) as temp:
    path = pathlib.Path(temp)
    private_localappdata = path / "LocalAppData"
    private_localappdata.mkdir()
    os.environ["LOCALAPPDATA"] = str(private_localappdata)
    return_root = private_localappdata / "GaoSeries" / "GaoAction" / "OcrReturns-v1"
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
            def wait(predicate, timeout=6):
                limit = time.monotonic() + timeout
                while time.monotonic() < limit:
                    if js(predicate): return
                    time.sleep(.06)
                raise AssertionError(f"{predicate}\n{js('document.body.innerText')}")
            def post(route, payload):
                result = command("Runtime.evaluate", {"expression": f"api({json.dumps('/api/' + route)}, {json.dumps(payload)})",
                    "awaitPromise": True, "returnByValue": True})
                assert not result.get("exceptionDetails"), result
                return result["result"]["value"]
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
                window.qaProviderPosts = [];
                window.fetch = (url, options) => {
                  if (url === '/api/ocr-provider/approve' || url === '/api/ocr-provider/return') window.qaProviderPosts.push(url);
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
            if options.preview_ocr:
                rule_id, workflow_id = str(uuid.uuid4()), str(uuid.uuid4())
                post("settings", {"windowsAutomationEnabled": True, "workflows": [{"id": workflow_id, "name": "合成压缩试跑",
                    "steps": [{"id": str(uuid.uuid4()), "actionID": action, "argument": ""}
                              for action in ("archive.create", "files.move", "window.leftHalf")]}]})
                post("rules/save", {"rules": [{"id": rule_id, "shortcut": "Ctrl+Alt+W", "trigger": "hotkey", "application": "notepad.exe",
                    "actionID": "window.leftHalf", "enabled": True}]})
                viewport(1160, 800, 1)
                set_theme("light")
                navigate("快捷键与手势")
                wait("document.querySelector('.rule-row')?.innerText.includes('notepad.exe')")
                click("试跑…", ".rule-row button")
                click("生成试跑计划", "dialog[open] button")
                wait("document.querySelector('.rule-preview-result')?.innerText.includes('预计动作与文件')")
                assert js("document.querySelector('.rule-preview-result').innerText.includes('不确定')")
                check_dialog()
                screenshot("rule-preview-light")
                js("document.querySelector('dialog[open] input').value = 'other.exe'")
                click("生成试跑计划", "dialog[open] button")
                wait("document.querySelector('.rule-preview-result')?.innerText.includes('试跑条件未命中')")
                click("取消", "dialog[open] button")
                click("编辑", ".rule-row button")
                js("document.querySelector('dialog[open] input[placeholder=\"Ctrl+Alt+W\"]').value = 'Ctrl+Alt+Q'")
                click("试跑草稿…", "dialog[open] button")
                click("生成试跑计划", "body > dialog[open] button")
                wait("document.querySelector('body > dialog[open] .rule-preview-result')?.innerText.includes('已生成试跑计划')")
                click("取消", "body > dialog[open] button")
                assert js("document.querySelector('dialog[open] input[placeholder=\"Ctrl+Alt+W\"]').value === 'Ctrl+Alt+Q'")
                assert post("rules/list", {})["rules"][0]["shortcut"] == "Ctrl+Alt+W"
                click("取消", "dialog[open] button")

                navigate("组合操作")
                set_theme("dark")
                viewport(428, 570, 1.5)
                click("试跑…", ".body button")
                simulated = str(path / "fictional" / "sample.png")
                planned = str(path / "fictional" / "sample 2.zip")
                js(f"const sampleFields = document.querySelectorAll('dialog[open] textarea'); sampleFields[0].value = {json.dumps(simulated)};"
                   f"sampleFields[1].value = {json.dumps(str(path / 'fictional' / 'sample.zip'))}")
                click("生成试跑计划", "dialog[open] button")
                wait(f"document.querySelector('.rule-preview-result')?.innerText.includes({json.dumps(planned)})")
                assert js("document.querySelector('.rule-preview-result').innerText.includes('缺少目标目录。')")
                assert js("document.querySelector('.rule-preview-result').innerText.includes('已跳过')")
                assert not (path / "fictional").exists()
                check_dialog()
                js(r"sampleFields[0].value = 'C:\\GaoPreview\\Inbox\\sample.png'; sampleFields[1].value = 'C:\\GaoPreview\\Inbox\\sample.zip'")
                click("生成试跑计划", "dialog[open] button")
                wait(r"document.querySelector('.rule-preview-result')?.innerText.includes('C:\\GaoPreview\\Inbox\\sample 2.zip')")
                screenshot("workflow-preview-dark-narrow-150")
                click("取消", "dialog[open] button")

                viewport(1160, 800, 1)
                set_theme("light")
                package, slot, issued = make_ocr_fixture(path, return_root, "com.gaoseries.GaoWenJian")
                app.activate({"package": str(package)})
                wait("document.querySelector('dialog[open] .ocr-return-status')?.innerText.includes('识别后回传给 搞文件 待审核')")
                assert not (slot / "result.gaoaction").exists()
                screenshot("ocr-return-approval-light")
                click("确认识别", "dialog[open] button")
                wait("document.querySelector('dialog[open] .ocr-return-status')?.innerText.includes('已回传给 搞文件')", timeout=25)
                package_manifest = json.loads((slot / "result.gaoaction" / "manifest.json").read_bytes())
                assert package_manifest["inReplyTo"] == issued["requestID"]
                assert package_manifest["provenance"]["requestManifestSHA256"] == issued["requestManifestSHA256"]
                assert not js("[...document.querySelectorAll('dialog[open] button')].some(button => button.innerText.trim() === '重试回传')")
                js("document.querySelector('dialog[open]').close()")

                set_theme("dark")
                viewport(428, 570, 1.5)
                package, slot, issued = make_ocr_fixture(path, return_root, "com.academic-achievement.manager", ticket=False)
                app.activate({"package": str(package)})
                wait("document.querySelector('dialog[open] .ocr-return-status')?.innerText.includes('当前无法自动回传给 搞研究')")
                click("确认识别", "dialog[open] button")
                wait("document.querySelector('dialog[open] h2')?.textContent === 'OCR 交接状态' && document.querySelector('.ocr-return-status')?.checkVisibility()", timeout=25)
                assert not (slot / "result.gaoaction").exists()
                assert js("[...document.querySelectorAll('dialog[open] button')].some(button => button.innerText.trim() === '导出结果…')")
                assert js("![...document.querySelectorAll('dialog[open] button')].some(button => button.innerText.trim() === '确认识别')")
                check_dialog()
                screenshot("ocr-return-unavailable-dark-narrow-150")
                write_return_ticket(slot, issued)
                click("重试回传", "dialog[open] button")
                wait("document.querySelector('dialog[open] .ocr-return-status')?.innerText.includes('已回传给 搞研究')")
                assert js("window.qaProviderPosts") == ["/api/ocr-provider/approve", "/api/ocr-provider/approve", "/api/ocr-provider/return"]
                assert (slot / "result.gaoaction" / "manifest.json").exists()
                check_dialog()
                screenshot("ocr-return-published-dark-narrow-150")
                assert not exceptions, exceptions
                print("Rule and workflow dry runs, native OCR approval and both recipients, manual fallback and return-only retry passed.")
                raise SystemExit(0)
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
