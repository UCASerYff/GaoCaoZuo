"""Run real Chromium encoding with synthetic Canvas and Web Audio sources.

Requires an installed Chromium browser, Pillow, and websocket-client. It does
not sample the Windows desktop or request microphone-device access.
"""

import argparse
from array import array
import base64
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote
from urllib.request import ProxyHandler, build_opener
import uuid
import wave

from PIL import Image
import websocket

WINDOWS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WINDOWS / "src"))
from gaocaozuo.app import App
from gaocaozuo.shell_win import browser_path
from gaocaozuo.web import serve


SETUP = r"""(() => {
  const calls = { display: 0, microphone: 0, saved: [] };
  const canvas = document.createElement('canvas');
  canvas.width = 320;
  canvas.height = 180;
  const context = canvas.getContext('2d');
  let frame = 0;
  const timer = setInterval(() => {
    context.fillStyle = frame % 2 ? 'navy' : 'white';
    context.fillRect(0, 0, 320, 180);
    context.fillStyle = 'orange';
    context.fillRect(frame++ % 50, 10, 45, 30);
  }, 50);
  const audios = [];
  async function audio() {
    const audio = new AudioContext();
    await audio.resume();
    const oscillator = audio.createOscillator();
    const gain = audio.createGain();
    gain.gain.value = 0.08;
    const target = audio.createMediaStreamDestination();
    oscillator.connect(gain).connect(target);
    oscillator.start();
    audios.push(audio);
    return target.stream;
  }
  navigator.mediaDevices.getDisplayMedia = async options => {
    ++calls.display;
    const stream = canvas.captureStream(20);
    if (options.audio) stream.addTrack((await audio()).getAudioTracks()[0]);
    return stream;
  };
  navigator.mediaDevices.getUserMedia = async options => {
    if (!options.audio || options.video) throw new Error('unexpected mic options');
    ++calls.microphone;
    return audio();
  };
  window.showSaveFilePicker = async options => ({
    name: options.suggestedName,
    createWritable: async () => ({
      write: async blob => calls.saved.push({ name: options.suggestedName, blob }),
      close: async () => {},
      abort: async () => {},
    }),
  });
  window.testRecording = { calls, stop: () => { clearInterval(timer); audios.forEach(context => context.close()); } };
  document.querySelectorAll('.nav button').forEach(button => {
    if (button.textContent.trim() === '截图与录制') button.click();
  });
  document.querySelectorAll('[role=tab]').forEach(button => {
    if (button.textContent.trim() === '录屏与录音') button.click();
  });
})()"""

VERIFY_TRACKS = r"""(async () => {
  const {Input, BlobSource, MP4, QTFF} = await import('/vendor/mediabunny.js');
  const results = [];
  for (const {name, blob} of testRecording.calls.saved.filter(item => !item.name.endsWith('.gif'))) {
    const input = new Input({source: new BlobSource(blob), formats: [MP4, QTFF]});
    try {
      const format = await input.getFormat();
      const video = await Promise.all((await input.getVideoTracks()).map(track => track.getCodec()));
      const audio = await Promise.all((await input.getAudioTracks()).map(track => track.getCodec()));
      const element = document.createElement(video.length ? 'video' : 'audio');
      const url = URL.createObjectURL(blob);
      let dimensions;
      try {
        dimensions = await new Promise((resolve, reject) => {
          element.addEventListener('loadeddata', () => resolve([element.duration, element.videoWidth, element.videoHeight]), {once: true});
          element.addEventListener('error', () => reject(new Error('Chromium playback cannot decode: ' + element.error?.message)), {once: true});
          element.src = url;
        });
      } finally { URL.revokeObjectURL(url); }
      results.push({name, quicktime: format === QTFF, video, audio, dimensions});
    } finally { input.dispose(); }
  }
  return results;
})()"""


class DevTools:
    def __init__(self, socket):
        self.socket = socket
        self.sequence = 0
        self.external = []

    def call(self, method, **params):
        self.sequence += 1
        self.socket.send(json.dumps({"id": self.sequence, "method": method, "params": params}))
        while True:
            message = json.loads(self.socket.recv())
            if message.get("id") == self.sequence:
                if "error" in message:
                    raise AssertionError(message["error"])
                return message["result"]
            if message.get("method") == "Network.requestWillBeSent":
                url = message["params"]["request"]["url"]
                if url.startswith(("http://", "https://")) and not url.startswith("http://127.0.0.1:"):
                    self.external.append(url)

    def evaluate(self, js):
        result = self.call("Runtime.evaluate", expression=js, awaitPromise=True, returnByValue=True, userGesture=True)
        if "exceptionDetails" in result:
            raise AssertionError(result.get("result", {}).get("description", result["exceptionDetails"]))
        return result["result"].get("value")

    def wait(self, description, condition):
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            if self.evaluate(condition):
                return
            time.sleep(0.08)
        raise AssertionError(f"{description}: {self.evaluate('document.body.innerText')}")

    def click(self, label):
        self.evaluate(f"[...document.querySelectorAll('button')].find(button => button.textContent.trim() === {json.dumps(label)}).click()")


def check_recording(client):
    client.wait("workbench ready", "document.querySelector('h1')?.textContent === '工作台'")
    client.evaluate(SETUP)
    client.click("开始录制")
    client.wait("recording started", "recording.status === 'recording'")
    time.sleep(0.4)
    client.click("暂停")
    client.wait("recording paused", "recording.status === 'paused'")
    client.click("继续")
    time.sleep(1.4)
    client.click("停止并完成")
    client.wait("screen recording available", "recording.status === 'ready'")
    client.click("生成 MOV")
    client.wait("QuickTime encoded", "mediaTools.prepared?.format === 'mov'")
    client.click("选择位置保存…")
    client.wait("QuickTime saved", "testRecording.calls.saved.length === 1 && recording.status === 'saved'")
    client.click("导出 M4A…")
    client.wait("audio extracted", "mediaTools.prepared?.format === 'm4a'")
    client.click("选择位置保存…")
    client.wait("extracted audio saved", "testRecording.calls.saved.length === 2")

    client.evaluate("Object.assign(mediaTools, {start:0, end:1, fps:6, size:120, crop:true, x:0, y:0, width:0.5, height:1}); render()")
    client.click("生成 GIF")
    client.wait("GIF encoded", "mediaTools.prepared?.format === 'gif'")
    client.click("选择位置保存…")
    client.wait("GIF saved", "testRecording.calls.saved.length === 3")
    gif = client.evaluate("(async () => btoa(String.fromCharCode(...new Uint8Array(await testRecording.calls.saved[2].blob.arrayBuffer()))))()")
    with Image.open(io.BytesIO(base64.b64decode(gif))) as image:
        assert image.format == "GIF" and image.n_frames == 6 and image.size == (107, 120)
        duration = 0
        for frame in range(image.n_frames):
            image.seek(frame)
            duration += image.info["duration"]
        assert duration == 1000

    client.evaluate("window.supportedRecorderMime = MediaRecorder.isTypeSupported.bind(MediaRecorder); MediaRecorder.isTypeSupported = mime => !mime.includes('mp4') && supportedRecorderMime(mime)")
    client.evaluate("Object.assign(recording, {mode:'audio', microphone:true, systemAudio:false}); render()")
    client.click("开始录制")
    client.wait("audio-only recording", "recording.status === 'recording'")
    time.sleep(1.1)
    client.click("停止并完成")
    client.wait("audio-only WebM source available", "recording.status === 'ready' && !recording.result.video && recording.result.blob.type.includes('webm')")
    client.click("生成 M4A")
    client.wait("audio-only AAC encoded", "mediaTools.prepared?.format === 'm4a'")
    client.click("选择位置保存…")
    client.wait("audio-only file saved", "recording.saved && testRecording.calls.saved.length === 4")

    client.evaluate("Object.assign(recording, {mode:'audio', microphone:true, systemAudio:true}); MediaRecorder.isTypeSupported = supportedRecorderMime; render()")
    client.click("开始录制")
    client.wait("shared audio-only recording", "recording.status === 'recording'")
    time.sleep(1.1)
    client.click("停止并完成")
    client.wait("audio-only MOV ready", "recording.status === 'ready' && recording.result.format === 'mov' && !recording.result.video")
    client.click("生成 MOV")
    client.wait("shared audio-only MOV encoded", "mediaTools.prepared?.format === 'mov'")
    client.click("选择位置保存…")
    client.wait("shared audio-only MOV saved", "recording.saved && testRecording.calls.saved.length === 5")
    saved = client.evaluate(VERIFY_TRACKS)
    screen, extracted, microphone, shared = saved
    assert screen["name"].endswith(".mov") and screen["quicktime"] and screen["video"] == ["avc"], screen
    assert screen["dimensions"][1:] == [320, 180], screen
    assert all(item["name"].endswith(".m4a") and not item["video"] for item in (extracted, microphone)), saved
    assert shared["name"].endswith(".mov") and shared["quicktime"] and not shared["video"], shared
    assert all(item["audio"] == ["aac"] and item["dimensions"][0] > 0 for item in saved), saved
    assert client.evaluate("testRecording.calls.display === 2 && testRecording.calls.microphone === 2")
    assert not client.external, client.external
    client.evaluate("testRecording.stop()")


def check_browser_tab_capture(client, title):
    html = ('<title>' + title + '</title><style>html {background: rgb(0, 160, 30);}</style>'
            '<script>let shade=156; setInterval(() => {shade=shade===156?164:156; '
            'document.documentElement.style.background=`rgb(0,${shade},30)`}, 80)</script>')
    fixture = client.call("Target.createTarget", url="data:text/html," + quote(html), background=True)["targetId"]
    try:
        client.call("Page.bringToFront")
        client.wait("synthetic tab ready", "document.hasFocus() && document.querySelector('h1')?.textContent === '工作台'")
        client.evaluate("""(() => {
          [...document.querySelectorAll('.nav button')].find(b => b.textContent.trim() === '截图与录制').click();
          [...document.querySelectorAll('[role=tab]')].find(b => b.textContent.trim() === '录屏与录音').click();
          recording.systemAudio = false;
          render();
        })()""")
        client.click("开始录制")
        client.wait("native Chromium tab capture", "recording.status === 'recording' && recording.streams[0].getVideoTracks()[0].getSettings().displaySurface === 'browser'")
        time.sleep(1.1)
        client.click("停止并完成")
        client.wait("native tab export source ready", "recording.status === 'ready'")
        client.call("Page.bringToFront")
        client.click("生成 MOV")
        client.wait("native tab MOV prepared", "mediaTools.prepared?.format === 'mov'")
        sample = client.evaluate("""(async () => {
          const video = document.createElement('video');
          const url = URL.createObjectURL(mediaTools.prepared.blob);
          try {
            await new Promise((resolve, reject) => {
              const timer = setTimeout(() => reject(new Error('No playable frame in captured tab MOV')), 7000);
              video.preload = 'auto';
              video.onloadeddata = () => { clearTimeout(timer); resolve(); };
              video.onerror = reject;
              video.src = url;
            });
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 2;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(video, 0, 0, 2, 2);
            return [...ctx.getImageData(1, 1, 1, 1).data];
          } finally { URL.revokeObjectURL(url); }
        })()""")
        assert sample[0] < 35 and 126 <= sample[1] <= 190 and sample[2] < 65, sample
        assert not client.external, client.external
        client.evaluate("mediaTools.prepared = null; recording.result = null")
    finally:
        client.call("Target.closeTarget", targetId=fixture)


def virtual_microphone_wave(path):
    rate = 48000
    samples = array("h", (int(5000 * math.sin(2 * math.pi * 440 * point / rate)) for point in range(rate * 2)))
    with wave.open(str(path), "wb") as file:
        file.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        file.writeframes(samples.tobytes())


def check_virtual_microphone(client):
    client.wait("workbench ready", "document.querySelector('h1')?.textContent === '工作台'")
    client.evaluate("""(() => {
      navigator.mediaDevices.getDisplayMedia = () => { throw new Error('unexpected screen access'); };
      [...document.querySelectorAll('.nav button')].find(b => b.textContent.trim() === '截图与录制').click();
      [...document.querySelectorAll('[role=tab]')].find(b => b.textContent.trim() === '录屏与录音').click();
      Object.assign(recording, {mode:'audio', microphone:true, systemAudio:false});
      render();
    })()""")
    client.click("开始录制")
    client.wait("Chromium virtual microphone recording", "recording.status === 'recording' && recording.streams.length === 1 && recording.streams[0].getAudioTracks().length === 1")
    time.sleep(1.3)
    client.click("停止并完成")
    client.wait("virtual microphone clip", "recording.status === 'ready' && recording.result.audio && !recording.result.video")
    client.click("生成 M4A")
    client.wait("virtual microphone M4A", "mediaTools.prepared?.format === 'm4a'")
    rms = client.evaluate("""(async () => {
      const context = new OfflineAudioContext(1, 1, 48000);
      const decoded = await context.decodeAudioData(await mediaTools.prepared.blob.arrayBuffer());
      const samples = decoded.getChannelData(0);
      return Math.sqrt(samples.reduce((value, sample) => value + sample * sample, 0) / samples.length);
    })()""")
    assert rms > 0.005, rms
    assert not client.external, client.external
    client.evaluate("mediaTools.prepared = null; recording.result = null")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", type=Path, default=browser_path())
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--native-tab", action="store_true", help="Exercise Chromium tab capture using only a uniquely titled synthetic tab")
    sources.add_argument("--virtual-microphone", action="store_true", help="Exercise Chromium microphone recording using a generated audio file")
    options = parser.parse_args()
    if not options.browser or not options.browser.is_file():
        parser.error("Specify an installed Chromium executable with --browser.")
    stash = WINDOWS / "build"
    stash.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="recording-qa-", dir=stash) as temporary:
        root = Path(temporary)
        app = App(root / "data")
        app.create_settings()
        app.update_settings({"language": "zh-Hans"})
        server = serve(app, open_browser=False)
        profile = root / "profile"
        flags = ["--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                 "--remote-debugging-port=0", "--enable-logging=stderr", f"--user-data-dir={profile}"]
        title = "GaoMediaFixture-" + uuid.uuid4().hex
        if options.native_tab:
            flags.append(f"--auto-select-tab-capture-source-by-title={title}")
        if options.virtual_microphone:
            wav = root / "virtual-microphone.wav"
            virtual_microphone_wave(wav)
            flags.extend(["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", f"--use-file-for-fake-audio-capture={wav}"])
        with (root / "chrome.log").open("w+b") as log:
            browser = subprocess.Popen([str(options.browser), *flags, "about:blank"], stdout=log, stderr=log,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
            socket = None
            try:
                endpoint = profile / "DevToolsActivePort"
                deadline = time.monotonic() + 10
                while not endpoint.is_file() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if not endpoint.is_file():
                    log.seek(0)
                    raise AssertionError(log.read().decode("utf-8", errors="replace"))
                port = endpoint.read_text().splitlines()[0]
                opener = build_opener(ProxyHandler({}))
                with opener.open(f"http://127.0.0.1:{port}/json", timeout=8) as response:
                    page = next(item for item in json.load(response) if item["type"] == "page")
                socket = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=24, suppress_origin=True)
                client = DevTools(socket)
                client.call("Network.enable")
                client.call("Page.navigate", url=server.url)
                if options.native_tab:
                    check_browser_tab_capture(client, title)
                elif options.virtual_microphone:
                    check_virtual_microphone(client)
                else:
                    check_recording(client)
            finally:
                if socket is not None:
                    try:
                        socket.send(json.dumps({"id": 0, "method": "Browser.close"}))
                    except OSError:
                        pass
                    socket.close()
                try:
                    browser.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    browser.terminate()
                    browser.wait(timeout=8)
                server.shutdown()
                server.server_close()
    if options.native_tab:
        print("Chromium getDisplayMedia captured only a synthetic tab and delivered its expected pixels in the exported MOV.")
    elif options.virtual_microphone:
        print("Chromium getUserMedia recorded a virtual microphone with generated audio and the M4A decoded to a verified non-silent signal.")
    else:
        print("Synthetic capture, pause/resume, QuickTime H.264/AAC MOV, WebM-to-M4A transcode, mixed audio-only MOV, playback, cropped GIF, and no external requests passed.")


if __name__ == "__main__":
    main()
