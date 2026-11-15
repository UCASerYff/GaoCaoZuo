import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaocaozuo.cli import main

import gaocaozuo.platform_win  # PyInstaller 需要看到 Windows 系统接口。

if __name__ == "__main__":
    raise SystemExit(main())
