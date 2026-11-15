"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gaocaozuo.app import App
from gaocaozuo.errors import AppError
from gaocaozuo.store import default_data_dir
from gaocaozuo.version import VERSION_LABEL
from gaocaozuo.web import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoCaoZuo", description="搞操作 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--paths", nargs="*", default=None)
    args = parser.parse_args(argv)
    if args.version:
        _write(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
    try:
        app = App(directory)
        if args.paths:
            app.selection = list(args.paths)
        server = serve(app, port=args.port, open_browser=not args.no_browser)
        _write(server.url)
    except AppError as exc:
        _write(exc.message, error=True)
        return 2
    try:
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def _write(text: str, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    if stream is None:
        return
    print(text, file=stream)
