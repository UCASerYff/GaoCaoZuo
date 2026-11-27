import json
import threading
import urllib.error
import urllib.request
import uuid

import pytest

from gaocaozuo.app import App
from gaocaozuo.errors import AppError
from gaocaozuo.web import OperationServer, serve


def test_desktop_exit_requires_current_browser_decision_through_shared_endpoint(tmp_path):
    app = App(tmp_path / "isolated")
    app.create_settings()
    server = serve(app, open_browser=False, desktop=True)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    client = str(uuid.uuid4())

    def post(route, payload):
        request = urllib.request.Request(server.url + "api/" + route, json.dumps(payload).encode(),
                                         {"X-Gao-Token": server.token, "Content-Type": "application/json"})
        with opener.open(request, timeout=5) as response:
            return json.load(response).get("result")

    def heartbeat():
        return post("lifecycle", {"clientID": client, "busy": False})

    try:
        with pytest.raises(urllib.error.HTTPError) as unavailable:
            post("lifecycle/hide", {})
        assert unavailable.value.code == 400 and not server.hide_requested.is_set()
        server.tray_available = lambda: True
        assert post("lifecycle/hide", {})["accepted"] and server.hide_requested.is_set()

        post("shutdown", {})
        first = heartbeat()["exitRequest"]
        assert first and not server.exit_accepted.is_set() and not server.shutdown_requested.is_set()
        post("lifecycle/exit", {"clientID": client, "requestID": first, "decision": "cancel"})
        assert heartbeat()["exitRequest"] is None
        post("settings", {"appearance": "dark"})
        assert app.store.settings["appearance"] == "dark"

        server.request_exit()  # Native tray callback uses the same request method.
        second = heartbeat()["exitRequest"]
        assert second and second != first
        for invalid in ({"clientID": client, "requestID": first}, {"clientID": str(uuid.uuid4()), "requestID": second}):
            with pytest.raises(urllib.error.HTTPError) as obsolete:
                post("lifecycle/exit", {**invalid, "decision": "confirm"})
            assert obsolete.value.code == 400 and not server.exit_accepted.is_set()
        assert post("lifecycle/exit", {"clientID": client, "requestID": second, "decision": "confirm"})["accepted"]
        with pytest.raises(urllib.error.HTTPError):
            post("settings", {"appearance": "light"})
        assert app.store.settings["appearance"] == "dark"
        assert server.finish_exit() and server.shutdown_requested.is_set()
    finally:
        server.shutdown()
        server.server_close()


def test_windowless_quit_waits_for_native_work_and_pending_paste_review(tmp_path):
    app = App(tmp_path / "isolated")
    with OperationServer(app, desktop=True) as server:
        server.request_exit()
        with server.lock:
            assert not server.try_accept_background_exit() and not server.exit_accepted.is_set()
        app.clipboard.transaction = object()
        assert server.try_accept_background_exit() and not server.exit_accepted.is_set()
        app.clipboard.transaction = None
        assert not server.try_accept_background_exit() and server.exit_accepted.is_set()
        entered, drained = threading.Event(), threading.Event()

        def finish():
            entered.set()
            if server.finish_exit():
                drained.set()

        with server.lock:
            worker = threading.Thread(target=finish)
            worker.start()
            assert entered.wait(2) and not drained.is_set()
        worker.join(3)
        assert drained.is_set() and not worker.is_alive()


def test_paste_restore_failure_leaves_desktop_open_and_can_retry(tmp_path, monkeypatch):
    app = App(tmp_path / "isolated")
    with OperationServer(app, desktop=True) as server:
        app.clipboard.transaction = object()
        client = {"clientID": str(uuid.uuid4()), "busy": True}

        def approve_exit():
            server.request_exit()
            info = server.lifecycle(client)
            assert info["pastePending"]
            server.decide_exit({**client, "requestID": info["exitRequest"], "decision": "confirm"})

        def blocked():
            raise AppError("synthetic restore conflict", "busy")

        monkeypatch.setattr(app.clipboard, "cancel", blocked)
        approve_exit()
        assert not server.finish_exit() and not server.shutdown_requested.is_set()
        assert server.lifecycle(client)["exitError"] == "synthetic restore conflict"
        assert not server.exit_accepted.is_set() and app.clipboard.transaction is not None

        def restored():
            app.clipboard.transaction = None

        monkeypatch.setattr(app.clipboard, "cancel", restored)
        approve_exit()
        assert server.finish_exit() and app.clipboard.transaction is None
