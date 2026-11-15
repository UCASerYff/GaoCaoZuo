"""只监听 127.0.0.1 的本地页面。请求体不写入日志。"""

from __future__ import annotations

import json
import mimetypes
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from gaocaozuo.app import App
from gaocaozuo.errors import AppError
from gaocaozuo.features import validate_package
from gaocaozuo.resources import asset_dir
from gaocaozuo.version import VERSION_LABEL


class OperationServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, app: App, host: str = "127.0.0.1", port: int = 0):
        if host not in {"127.0.0.1", "localhost"}:
            raise AppError("页面只监听本机回环地址。", "invalid")
        self.app = app
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.shutdown_requested = threading.Event()
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"


class Handler(BaseHTTPRequestHandler):
    server: OperationServer

    def do_GET(self) -> None:
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
        if parsed.path == "/api/export/snippets.csv":
            if not self._authorized():
                return
            with self.server.lock:
                text = self.server.app.snippets.export_csv()
            self._bytes(text.encode("utf-8"), "text/csv; charset=utf-8")
            return
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not self._authorized():
            return
        if parsed.path == "/api/shutdown":
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        try:
            payload = self._body()
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
            return
        try:
            with self.server.lock:
                result = dispatch(self.server.app, parsed.path, payload)
                state = self.server.app.snapshot()
            self._json({"ok": True, "result": result, "state": state})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        if self.headers.get("X-Gao-Token") == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 32 * 1024 * 1024:
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
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(app: App, path: str, payload: dict):
    if path == "/api/settings/create":
        return app.create_settings()
    if path == "/api/settings":
        return app.update_settings(payload)
    if path == "/api/favorites/toggle":
        return {"favorites": app.store.toggle_favorite(payload["id"])}
    if path == "/api/action":
        return app.perform(payload["id"], payload.get("payload") or {})
    if path == "/api/workflows/save":
        return app.save_workflow(payload)
    if path == "/api/undo":
        return app.undo(payload.get("ids") or [])
    if path == "/api/clipboard/remember":
        item = app.clipboard.remember(payload.get("text") or "", payload.get("sourceApp") or "", payload.get("kind") or "text")
        return {"stored": item is not None, "item": item}
    if path == "/api/clipboard/search":
        return {"items": app.clipboard.search(payload.get("query") or "")}
    if path == "/api/paste/confirm":
        return app.clipboard.confirm()
    if path == "/api/paste/cancel":
        return app.clipboard.cancel()
    if path == "/api/paste/enter":
        return app.clipboard.enter(payload.get("role"), bool(payload.get("editable")))
    if path == "/api/paste/stack":
        return {"parts": app.clipboard.push_stack(payload.get("parts") or [])}
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
        return app.screenshots.annotate(payload["id"], payload.get("rects") or [])
    if path == "/api/screenshot/stitch":
        return app.screenshots.stitch(payload.get("ids") or [], int(payload.get("overlap") or 0))
    if path == "/api/screenshot/save":
        return {"path": app.screenshots.save(payload["id"], __import__("pathlib").Path(payload["directory"]))}
    if path == "/api/screenshot/pin":
        return {"path": app.screenshots.pin(payload["id"])}
    if path == "/api/lock/tick":
        return app.idle.tick(float(payload.get("idleSeconds") or 0), bool(payload.get("activity")), bool(payload.get("busy")))
    if path == "/api/snap":
        return app.snap(float(payload["x"]), float(payload["y"]), payload.get("screens") or [])
    raise AppError("没有这个操作。", "invalid")


def serve(app: App, port: int = 0, open_browser: bool = True) -> OperationServer:
    server = OperationServer(app, port=port)
    thread = threading.Thread(target=server.serve_forever, name="gaocaozuo-http", daemon=True)
    thread.start()
    if open_browser:
        import webbrowser

        try:
            webbrowser.open(server.url)
        except Exception:
            pass
    return server
