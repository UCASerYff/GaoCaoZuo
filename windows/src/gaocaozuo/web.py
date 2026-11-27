"""只监听 127.0.0.1 的本地页面。请求体不写入日志。"""

from __future__ import annotations

import json
import mimetypes
import secrets
import threading
import uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from gaocaozuo.app import App
from gaocaozuo.errors import AppError
from gaocaozuo.localization import native_locale
from gaocaozuo.features import validate_package
from gaocaozuo.resources import asset_dir
from gaocaozuo.surface_win import native_surface
from gaocaozuo.version import VERSION_LABEL


class OperationServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, app: App, host: str = "127.0.0.1", port: int = 0, *, desktop: bool = False):
        if host not in {"127.0.0.1", "localhost"}:
            raise AppError("页面只监听本机回环地址。", "invalid")
        self.app = app
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.desktop = desktop
        self.tray_available = lambda: False
        self.hide_requested = threading.Event()
        self.exit_accepted = threading.Event()
        self.shutdown_requested = threading.Event()
        self._lifecycle_lock = threading.Lock()
        self._exit_request = None
        self._exit_client = None
        self._exit_error = None
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"

    @property
    def exit_request(self):
        with self._lifecycle_lock:
            return self._exit_request

    def request_exit(self) -> None:
        with self._lifecycle_lock:
            if self._exit_request is None:
                self._exit_request = secrets.token_urlsafe(18)
                self._exit_error = None
            if not self.desktop:
                self.exit_accepted.set()

    def _paste_pending(self) -> bool:
        return self.app.clipboard.transaction is not None

    def lifecycle(self, payload: dict) -> dict:
        client = _lifecycle_client(payload)
        if type(payload.get("busy")) is not bool:
            raise AppError("工作台会话状态无效。", "invalid")
        with self._lifecycle_lock:
            if self.desktop and not self.exit_accepted.is_set():
                self._exit_client = client
            return {"desktop": self.desktop, "exitRequest": self._exit_request if self.desktop else None,
                    "pastePending": self._paste_pending(), "exitError": self._exit_error}

    def decide_exit(self, payload: dict) -> None:
        client = _lifecycle_client(payload)
        decision = payload.get("decision")
        with self._lifecycle_lock:
            if (not self.desktop or self.exit_accepted.is_set() or self._exit_request is None or
                    payload.get("requestID") != self._exit_request or client != self._exit_client or
                    decision not in ("confirm", "cancel")):
                raise AppError("退出请求已失效，请重新选择退出。", "changed")
            if decision == "cancel":
                self._exit_request = None
            else:
                self.exit_accepted.set()

    def window_closed(self) -> None:
        with self._lifecycle_lock:
            self._exit_client = None

    def try_accept_background_exit(self) -> bool:
        """Return whether the workbench must reopen to resolve a pending paste."""
        if not self.lock.acquire(blocking=False):
            return False
        try:
            with self._lifecycle_lock:
                if self._exit_request is not None and not self.exit_accepted.is_set():
                    if self._paste_pending():
                        return True
                    self.exit_accepted.set()
        finally:
            self.lock.release()
        return False

    def cancel_exit(self, detail: str) -> None:
        with self._lifecycle_lock:
            self._exit_request = None
            self._exit_error = detail
            self.exit_accepted.clear()

    def finish_exit(self) -> bool:
        # Already submitted writes, OCR and native file dialogs use this lock.
        with self.lock:
            if self.shutdown_requested.is_set():
                return True
            if not self.exit_accepted.is_set():
                return False
            try:
                if self._paste_pending():
                    self.app.clipboard.cancel()
            except (AppError, OSError) as exc:
                self.cancel_exit(exc.message if isinstance(exc, AppError) else "未能恢复剪贴板，搞操作仍在运行。")
                return False
            self.shutdown_requested.set()
        return True

    def stop_headless(self) -> None:
        if self.finish_exit():
            self.shutdown()


def _lifecycle_client(payload: dict) -> str:
    raw = payload.get("clientID")
    try:
        if not isinstance(raw, str) or len(raw) != 36:
            raise ValueError
        return uuid.UUID(raw).hex
    except ValueError as exc:
        raise AppError("工作台会话状态无效。", "invalid") from exc


class Handler(BaseHTTPRequestHandler):
    server: OperationServer

    def do_GET(self) -> None:
        if not self._local_request():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                self._json(self.server.app.snapshot())
            return
        if parsed.path == "/api/search":
            if not self._authorized():
                return
            query = parse_qs(parsed.query).get("q", [""])[0]
            with self.server.lock:
                self._json({"actions": self.server.app.search(query)})
            return
        if parsed.path == "/api/localization":
            if not self._authorized():
                return
            from gaocaozuo.localization import language_dictionary

            language = parse_qs(parsed.query).get("lang", ["zh-Hans"])[0]
            self._json({"strings": language_dictionary(language)})
            return
        if parsed.path == "/api/export/snippets.csv":
            if not self._authorized():
                return
            with self.server.lock:
                text = self.server.app.snippets.export_csv()
            self._bytes(text.encode("utf-8"), "text/csv; charset=utf-8")
            return
        if parsed.path == "/api/export/snippets.xlsx":
            if not self._authorized():
                return
            with self.server.lock:
                contents = self.server.app.snippets.export_xlsx()
            self._bytes(contents, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            return
        if parsed.path == "/api/screenshot/preview":
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    png = self.server.app.screenshots.preview(parse_qs(parsed.query).get("id", [""])[0])
                self._bytes(png, "image/png")
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 404)
            return
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if parsed.path == "/operation-icon.png" and not asset.exists() and len(root.parents) > 3:
            asset = root.parents[3] / "Assets" / "AppIcon.png"
            if asset.is_file():
                self._bytes(asset.read_bytes(), "image/png")
                return
        if asset.suffix.lower() in {".js", ".css", ".png", ".svg", ".woff2"} and asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        if not self._local_request():
            return
        parsed = urlparse(self.path)
        if not self._authorized():
            return
        try:
            payload = self._body()
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
            return
        try:
            if parsed.path == "/api/shutdown":
                self.server.request_exit()
                self._json({"ok": True})
                if not self.server.desktop:
                    threading.Thread(target=self.server.stop_headless, daemon=True).start()
                return
            if parsed.path == "/api/lifecycle":
                self._json({"ok": True, "result": self.server.lifecycle(payload)})
                return
            if parsed.path in {"/api/lifecycle/exit", "/api/lifecycle/hide"}:
                if parsed.path.endswith("/exit"):
                    self.server.decide_exit(payload)
                elif self.server.desktop and self.server.tray_available() and self.server.exit_request is None:
                    self.server.hide_requested.set()
                else:
                    raise AppError("当前会话没有可收起的工作台。", "unavailable")
                self._json({"ok": True, "result": {"accepted": True}})
                return
            with self.server.lock:
                if self.server.exit_accepted.is_set():
                    raise AppError("搞操作正在退出，请稍后重新打开。", "busy")
                app = self.server.app
                settings = app.store.settings or {}
                with native_locale(settings.get("language", "system")), native_surface(settings.get("appearance", "system")):
                    result = dispatch(app, parsed.path, payload)
                    response = {"ok": True, "result": result}
                    if parsed.path != "/api/rules/preview":
                        response["state"] = app.snapshot()
            self._json(response)
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
        except (KeyError, TypeError, ValueError, OSError):
            self._json({"ok": False, "error": "操作所需的参数无效，或系统无法读取或写入指定文件。", "code": "invalid"}, 400)

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        supplied = self.headers.get("X-Gao-Token", "")
        if supplied.isascii() and secrets.compare_digest(supplied, self.server.token):
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _local_request(self) -> bool:
        port = self.server.server_address[1]
        host = self.headers.get("Host", "").lower()
        origin = self.headers.get("Origin")
        if host in {f"127.0.0.1:{port}", f"localhost:{port}"} and origin in {None, f"http://{host}"} and self.headers.get("Sec-Fetch-Site") in {None, "none", "same-origin"}:
            return True
        self._json({"error": "请求并非来自本机工作台。"}, 403)
        return False

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as exc:
            raise AppError("请求大小声明无效。", "invalid") from exc
        if length < 0 or length > 32 * 1024 * 1024:
            raise AppError("上传超过 32 MiB。", "invalid")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise AppError("请求体不是 JSON。", "invalid") from exc
        if not isinstance(data, dict):
            raise AppError("请求体须为 JSON 对象。", "invalid")
        return data

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(body, "application/json; charset=utf-8", status)

    def _bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(app: App, path: str, payload: dict):
    if path == "/api/archive/edit/preview":
        return app.archive_editor.preview(Path(payload["path"]), payload.get("password"))
    if path == "/api/archive/edit/save":
        return app.archive_editor.save(payload)
    translation = "/api/screenshot/translate"
    if path == translation or path.startswith(translation + "/"):
        endpoint = path[len(translation):].lstrip("/") or "translate"
        if endpoint == "download" and app.store.status != "ready":
            raise AppError("请先建立可写的本机设置，再下载语言包。", "unavailable")
        if endpoint == "input" and payload.get("mode") == "clipboard":
            if payload.get("confirm") is not True or app.native_clipboard is None:
                raise AppError("请确认读取系统剪贴板。", "confirmation")
            return {"text": app.native_clipboard.text()}
        return app.translation.dispatch(endpoint, payload)
    if path == "/api/rules/cloud/status":
        return app.rule_cloud.poll(force=payload.get("force") is True)
    if path == "/api/rules/cloud/configure":
        if app.store.status != "ready":
            raise AppError("请先建立可写的本机设置，再配置规则同步。", "unavailable")
        return app.rule_cloud.configure(payload.get("folder"), payload.get("confirm"))
    if path == "/api/rules/cloud/resolve":
        if payload.get("confirm") is not True:
            raise AppError("请确认规则冲突的处理选择。", "confirmation")
        return app.rule_cloud.poll(force=True, choice=payload.get("choice"), token=payload.get("token"))
    if path == "/api/rules/cloud/approve":
        return app.rule_cloud.approve(payload["id"], payload.get("accept") is True, payload.get("confirm"))
    if path == "/api/activate":
        return app.activate(payload)
    if path == "/api/ocr-provider/review":
        return app.ocr_provider.receive(Path(payload["path"]))
    if path == "/api/ocr-provider/approve":
        return app.remember_ocr_review(app.ocr_provider.approve(payload["requestID"], payload.get("confirm") is True))
    if path == "/api/ocr-provider/return":
        return app.remember_ocr_review(app.ocr_provider.return_result(payload["requestID"]))
    if path == "/api/ocr-provider/result":
        return app.ocr_provider.export_result(payload["requestID"], Path(payload["directory"]), payload.get("confirm") is True)
    if path == "/api/ocr-provider/jobs":
        return {"jobs": app.ocr_provider.jobs()}
    if path == "/api/ocr-provider/capabilities":
        from gaocaozuo.ocr_provider import capabilities

        return capabilities()
    if path == "/api/settings/create":
        return app.create_settings()
    if path == "/api/settings":
        return app.update_settings(payload)
    if path == "/api/files/pick":
        from gaocaozuo.shell_win import pick_file

        if not app.desktop:
            raise AppError("此会话未打开交互工作台。", "unavailable")
        return {"paths": pick_file(payload.get("kind", "files"), bool(payload.get("multiple")))}
    if path == "/api/favorites/toggle":
        return {"favorites": app.store.toggle_favorite(payload["id"])}
    if path == "/api/action":
        arguments = payload.get("payload") or {}
        if not isinstance(arguments, dict) or {"nativeTarget", "backend"} & arguments.keys():
            raise AppError("此请求含仅可由 Windows 内部设置的参数。", "invalid")
        return app.perform(payload["id"], arguments)
    if path == "/api/workflows/save":
        return app.save_workflow(payload)
    if path == "/api/undo":
        return app.undo(payload.get("ids") or [])
    if path == "/api/clipboard/remember":
        item = app.clipboard.remember(payload.get("text") or "", payload.get("sourceApp") or "", payload.get("kind") or "text")
        return {"stored": item is not None, "item": item}
    if path == "/api/clipboard/search":
        return {"items": app.clipboard.search(payload.get("query") or "")}
    if path == "/api/clipboard/item":
        return app.clipboard_item(payload)
    if path == "/api/clipboard/clear":
        app.clipboard.replace_items([] if payload.get("includePinned") else [item for item in app.clipboard.items if item.get("pinned")])
        return {"items": app.clipboard.items}
    if path == "/api/paste/confirm":
        return app.clipboard.confirm()
    if path == "/api/paste/cancel":
        return app.clipboard.cancel()
    if path == "/api/paste/enter":
        return app.clipboard.enter(payload.get("role"), bool(payload.get("editable")))
    if path == "/api/paste/stack":
        return {"parts": app.clipboard.push_stack(payload.get("parts") or [])}
    if path == "/api/paste/stack/current":
        return {"parts": getattr(app.clipboard, "multiple", [])}
    if path == "/api/paste/stack/clear":
        if app.native_clipboard:
            if app.clipboard.transaction:
                raise AppError("请先处理等待核对的粘贴。", "busy")
            app.clipboard.multiple.clear()
        return {"parts": []}
    if path == "/api/paste/stack/paste":
        if not app.native_clipboard:
            raise AppError("此会话没有系统剪贴板。", "unavailable")
        contents = app.clipboard.native.part_formats(app.clipboard.multiple, temporary=True)
        return app.clipboard.begin_native(contents, payload.get("targetID"), stack_count=len(app.clipboard.multiple))
    if path == "/api/snippets/save":
        record = app.snippets.save_snippet(payload)
        if app.store.settings is not None:
            snippets = [item for item in app.store.settings.get("snippets") or [] if item.get("id") != record["id"]]
            snippets.append({"id": record["id"], "name": record["name"], "text": record["text"]})
            app.store.settings["snippets"] = snippets
            app.store.settings_doc.replace(app.store.settings)
        return record
    if path == "/api/snippets/resolve":
        text = app.snippets.resolve(payload["id"], __import__("datetime").datetime.now(), payload.get("clipboard"), bool(payload.get("secureInput")))
        return {"text": text}
    if path == "/api/rules/save":
        return app.save_rules(payload.get("rules") or [])
    if path == "/api/rules/list":
        return {"rules": app.rules()}
    if path == "/api/rules/preview":
        from gaocaozuo.rule_preview import preview_rule

        settings = app.store.settings or {}
        rules = app.rules() if payload.get("kind", "rule") == "rule" else []
        return preview_rule(payload, rules=rules, workflows=settings.get("workflows") or [], settings=settings)
    if path == "/api/rules/import":
        return app.import_input(payload.get("remote") or [], payload.get("tombstones") or [])
    if path == "/api/exchange/ticket":
        token = app.handoff.issue(payload.get("action") or "", payload.get("paths") or [], float(payload.get("now") or 0))
        return {"issued": True, "token": token}
    if path == "/api/exchange/consume":
        return app.handoff.consume(payload["token"], float(payload.get("now") or 0))
    if path == "/api/exchange/payload":
        return app.handoff.submit_payload_url(payload["url"])
    if path == "/api/exchange/approve":
        return app.handoff.approve(payload["reviewID"])
    if path == "/api/exchange/package":
        return validate_package(payload.get("document") or {}, payload.get("now") or "")
    if path == "/api/screenshot/annotate":
        return app.screenshots.annotate(payload["id"], payload.get("rects") or [], payload.get("commands"))
    if path == "/api/screenshot/stitch":
        return app.screenshots.stitch(payload.get("ids") or [], payload.get("overlap"))
    if path == "/api/screenshot/save":
        return {"path": app.screenshots.save(payload["id"], Path(payload["directory"]), payload.get("filename"))}
    if path == "/api/screenshot/pin":
        return {"path": app.screenshots.pin(payload["id"], payload.get("persistent", True))}
    if path == "/api/screenshot/open":
        return app.screenshots.open(Path(payload["path"]))
    if path == "/api/screenshot/history":
        return app.screenshots.history(payload.get("enabled"))
    if path == "/api/screenshot/history/open":
        return app.screenshots.history_open(payload["name"], bool(payload.get("pin")))
    if path == "/api/screenshot/long":
        from contextlib import nullcontext

        confirmed = payload.get("confirm") is True
        with app.capture_context() if payload["command"] in {"start", "auto"} and confirmed and not payload.get("bounds") else nullcontext():
            return app.screenshots.long_capture(payload["command"], confirmed, payload.get("delay"), payload.get("bounds"), payload.get("overlap"))
    if path == "/api/screenshot/ocr":
        paths = payload.get("paths") or None
        return app.screenshots.ocr(bool(payload.get("confirm")), image_id=payload.get("id"),
                                   paths=[Path(path) for path in paths] if paths else None, languages=payload.get("languages"))
    if path == "/api/screenshot/ocr/languages":
        return app.screenshots.ocr_languages()
    if path == "/api/screenshot/ocr/export":
        return app.screenshots.ocr_export(payload["id"], Path(payload["directory"]), payload.get("format", "txt"))
    if path == "/api/screenshot/ocr/edit":
        return app.screenshots.recognizer.edit(payload["id"], int(payload["sourceIndex"]), int(payload["pageNumber"]), int(payload["lineIndex"]), payload["text"])
    if path == "/api/screenshot/copy":
        if not app.native_clipboard:
            raise AppError("此会话没有系统剪贴板。", "unavailable")
        return app.clipboard.copy_image(app.screenshots.preview(payload["id"]))
    if path == "/api/lock/tick":
        if app.runtime:
            return app.idle.snapshot()
        return app.idle.tick(float(payload.get("idleSeconds") or 0), bool(payload.get("activity")), bool(payload.get("busy")))
    if path == "/api/lock/cancel":
        return app.idle.cancel()
    if path == "/api/snap":
        return app.snap(float(payload["x"]), float(payload["y"]), payload.get("screens") or [])
    raise AppError("没有这个操作。", "invalid")


def serve(app: App, port: int = 0, open_browser: bool = True, *, desktop: bool = False) -> OperationServer:
    server = OperationServer(app, port=port, desktop=desktop)
    thread = threading.Thread(target=server.serve_forever, name="gaocaozuo-http", daemon=True)
    thread.start()
    if open_browser:
        import webbrowser

        try:
            webbrowser.open(server.url)
        except Exception:
            pass
    return server
