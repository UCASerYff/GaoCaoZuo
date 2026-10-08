#!/usr/bin/env python3
"""Increment the app version by exactly 0.01 and build by 1."""
from decimal import Decimal
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
build = (root / 'BUILD').read_text().strip()
if not re.fullmatch(r'\d+\.\d{2}',version) or not re.fullmatch(r'[1-9]\d*',build):
    raise SystemExit('版本格式错误；未修改配置。')
(root / 'VERSION').write_text(f'{Decimal(version)+Decimal("0.01"):.2f}\n')
(root / 'BUILD').write_text(f'{int(build)+1}\n')
print(f'V{Decimal(version)+Decimal("0.01"):.2f} / build {int(build)+1}')
