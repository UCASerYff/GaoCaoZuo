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


def main(argv: list[str] | None = None, *, console: bool = False) -> int:
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
    headless = args.no_browser or args.serve or console
    interactive = not headless and os.name == "nt"
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
                can_forward = interactive or bool(paths or package)
                if can_forward and instance.handoff(paths, package):
                    return 0
                raise AppError("此资料目录已有一个搞操作会话。", "busy")
        app = App(directory, interactive=interactive)
        app.activate({"paths": paths})
        if package:
            try:
                app.activate({"package": package})
            except AppError as exc:
                if not interactive:
                    raise
                app.last_message = exc.message
        server = serve(app, port=args.port, open_browser=not headless and not interactive, desktop=interactive)
        if interactive:
            from gaocaozuo.runtime_win import WindowsRuntime
            from gaocaozuo.localization import native_locale
            from gaocaozuo.shell_win import WorkbenchWindow
            from gaocaozuo.surface_win import native_surface
            from gaocaozuo.tray_win import WindowsTray

            def read_language():
                return (app.store.settings or {}).get("language", "system")

            def read_appearance():
                return (app.store.settings or {}).get("appearance", "system")

            def invoke(action_id, payload):
                if not server.lock.acquire(blocking=False):
                    raise AppError("另一个搞操作任务正在运行。", "busy")
                try:
                    if server.exit_accepted.is_set():
                        raise AppError("搞操作正在退出，请稍后重新打开。", "busy")
                    with native_locale(read_language()), native_surface(read_appearance()):
                        result = app.perform(action_id, payload)
                    if result.get("show") and app.activation:
                        app.activation()
                finally:
                    server.lock.release()

            def on_tick():
                if server.lock.acquire(blocking=False):
                    try:
                        if not server.exit_accepted.is_set():
                            app.clipboard.observe()
                    finally:
                        server.lock.release()

            app.runtime = WindowsRuntime(app.desktop, app.system, app.idle, invoke,
                                         busy=lambda: server.lock.locked() or server.exit_accepted.is_set(),
                                         on_tick=on_tick, read_language=read_language, read_appearance=read_appearance)
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
                            if not server.exit_accepted.is_set():
                                app.rule_cloud.poll()
                        finally:
                            server.lock.release()

            cloud_worker = Thread(target=synchronize_rules, name="gaocaozuo-cloud-rules", daemon=True)
            cloud_worker.start()
            show_requested = Event()
            tray = WindowsTray(show_requested.set, server.request_exit)
            tray.configure(True)
            server.tray_available = lambda: tray.registered
            app.activation = show_requested.set
            app.capture_context = lambda: window.hidden_for_capture() if window else nullcontext()
            window = WorkbenchWindow(server.url)
            app.desktop.set_ui_pid(window.process.pid)
            tray.start()
            shown_exit = None
        if instance is not None:
            instance.publish(server)
        _write(server.url)
        while not server.shutdown_requested.wait(0.15):
            if not interactive:
                continue
            if server.exit_accepted.is_set() and server.finish_exit():
                break
            if window is not None and window.process.poll() is not None:
                window.close()
                window = None
                server.window_closed()
                app.desktop.set_ui_pid(None)
            exit_request = server.exit_request
            if exit_request is not None:
                if window is None:
                    if server.try_accept_background_exit():
                        show_requested.set()
                    if server.exit_accepted.is_set():
                        continue
                elif exit_request != shown_exit:
                    show_requested.set()
                    shown_exit = exit_request
            if server.hide_requested.is_set():
                server.hide_requested.clear()
                if window is not None and exit_request is None and tray.registered:
                    window.hide()
            if show_requested.is_set() and not server.lock.locked():
                show_requested.clear()
                if window is None:
                    try:
                        window = WorkbenchWindow(server.url)
                        app.desktop.set_ui_pid(window.process.pid)
                    except AppError as exc:
                        if exit_request is not None:
                            server.cancel_exit(exc.message)
                        from gaocaozuo.localization import native_text
                        from gaocaozuo.shell_win import show_error

                        with native_locale(read_language()):
                            show_error(native_text(exc.message))
                elif not window.activate():
                    # The Chromium HWND can disappear before its process exits after a window close.
                    show_requested.set()
    except KeyboardInterrupt:
        pass
    except (AppError, OSError) as exc:
        message = exc.message if isinstance(exc, AppError) else "Windows 无法启动搞操作或打开指定资料目录。"
        if interactive and sys.stderr is None:
            from gaocaozuo.localization import native_locale, native_text
            from gaocaozuo.shell_win import show_error

            with native_locale((app.store.settings or {}).get("language", "system") if app else "system"):
                show_error(native_text(message))
        else:
            _write(message, error=True)
        return 2
    finally:
        if server is not None:
            server.shutdown_requested.set()
        if cloud_worker is not None:
            cloud_worker.join(1)
        if app is not None and app.runtime is not None:
            app.runtime.close()
        elif app is not None:
            app.system.close()
        if app is not None:
            app.translation.close(wait=server is not None and server.exit_accepted.is_set())
        if app is not None and app.native_clipboard is not None and app.clipboard.transaction:
            try:
                app.clipboard.cancel()
            except AppError:
                pass
        if window is not None:
            window.close()
        if tray is not None:
            tray.close()
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
