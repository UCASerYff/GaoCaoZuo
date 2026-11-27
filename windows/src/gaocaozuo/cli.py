"""Desktop and headless entry points."""

from __future__ import annotations

import argparse
import json
import os
import sys
from contextlib import nullcontext
from pathlib import Path
from threading import Event, Thread

from gaocaozuo.app import App
from gaocaozuo.errors import AppError
from gaocaozuo.store import default_data_dir
from gaocaozuo.version import VERSION_LABEL
from gaocaozuo.web import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoCaoZuo", description="搞操作 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--capabilities", action="store_true")
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--paths", nargs="*")
    parser.add_argument("--gaoaction", help="在工作台审核本机 .gaoaction 请求目录")
    args = parser.parse_args(argv)
    if args.version:
        _write(VERSION_LABEL)
        return 0
    if args.capabilities:
        from gaocaozuo.ocr_provider import capabilities

        _write(json.dumps(capabilities(), ensure_ascii=True))
        return 0
    directory = (args.data_dir or default_data_dir()).resolve()
    interactive = not args.no_browser and os.name == "nt"
    instance = server = window = app = tray = cloud_worker = None
    paths = [str(Path(p).absolute()) for p in (args.paths or [])]
    package = args.gaoaction
    if not package and len(paths) == 1 and Path(paths[0]).suffix.lower() == ".gaoaction":
        package = paths.pop()
    try:
        if os.name == "nt":
            from gaocaozuo.shell_win import WorkbenchInstance

            instance = WorkbenchInstance(directory)
            if not instance.primary:
                if not interactive or not instance.handoff(paths, package):
                    raise AppError("此资料目录已有一个搞操作会话。", "busy")
                return 0
        app = App(directory, interactive=interactive)
        app.activate({"paths": paths})
        if package:
            try:
                app.activate({"package": package})
            except AppError as exc:
                if not interactive:
                    raise
                app.last_message = exc.message
        server = serve(app, port=args.port, open_browser=not args.no_browser and not interactive)
        if instance is not None:
            instance.publish(server)
        if interactive:
            from gaocaozuo.runtime_win import WindowsRuntime
            from gaocaozuo.shell_win import WorkbenchWindow
            from gaocaozuo.tray_win import WindowsTray

            def invoke(action_id, payload):
                if not server.lock.acquire(blocking=False):
                    raise AppError("另一个搞操作任务正在运行。", "busy")
                try:
                    result = app.perform(action_id, payload)
                    if result.get("show") and app.activation:
                        app.activation()
                finally:
                    server.lock.release()

            def on_tick():
                if server.lock.acquire(blocking=False):
                    try:
                        app.clipboard.observe()
                    finally:
                        server.lock.release()

            app.runtime = WindowsRuntime(app.desktop, app.system, app.idle, invoke, busy=server.lock.locked, on_tick=on_tick)
            try:
                app.configure_runtime()
            except AppError as exc:
                app.last_message = exc.message
                app.runtime.configure([], paused=True)
            app.runtime.start()
            def synchronize_rules():
                while not server.shutdown_requested.wait(15):
                    if server.lock.acquire(blocking=False):
                        try:
                            app.rule_cloud.poll()
                        finally:
                            server.lock.release()

            cloud_worker = Thread(target=synchronize_rules, name="gaocaozuo-cloud-rules", daemon=True)
            cloud_worker.start()
            show_requested = Event()
            tray = WindowsTray(show_requested.set, server.shutdown_requested.set)
            app.tray = tray
            tray.configure((app.store.settings or {}).get("showMenuBarIcon", True))
            tray.start()
            window = WorkbenchWindow(server.url)
            app.activation = show_requested.set
            app.capture_context = lambda: window.hidden_for_capture() if window else nullcontext()
            app.desktop.set_ui_pid(window.process.pid)
        _write(server.url)
        while not server.shutdown_requested.wait(0.25):
            if not interactive:
                continue
            if window is not None and window.process.poll() is not None:
                window.close()
                window = None
                app.desktop.set_ui_pid(None)
            if show_requested.is_set():
                show_requested.clear()
                if window is None:
                    window = WorkbenchWindow(server.url)
                    app.desktop.set_ui_pid(window.process.pid)
                else:
                    window.activate()
            if window is None and not tray.registered:
                break
    except KeyboardInterrupt:
        pass
    except (AppError, OSError) as exc:
        message = exc.message if isinstance(exc, AppError) else "Windows 无法启动搞操作或打开指定资料目录。"
        if interactive and sys.stderr is None:
            from gaocaozuo.shell_win import show_error

            show_error(message)
        else:
            _write(message, error=True)
        return 2
    finally:
        if server is not None:
            server.shutdown_requested.set()
        if cloud_worker is not None:
            cloud_worker.join(1)
        if app is not None:
            app.translation.close()
        if tray is not None:
            tray.close()
        if app is not None and app.runtime is not None:
            app.runtime.close()
        if app is not None and app.native_clipboard is not None and app.clipboard.transaction:
            try:
                app.clipboard.cancel()
            except AppError:
                pass
        if window is not None:
            window.close()
        if server is not None:
            server.shutdown()
            server.server_close()
        if instance is not None:
            instance.close()
    return 0


def _write(text: str, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    if stream is not None:
        print(text, file=stream, flush=True)
