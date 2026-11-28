"""营销版本与当前 Mac 版 VERSION 对齐。

Windows 构建号单独从 1 起算，不改 Mac 的 BUILD。
"""

MARKETING_VERSION = "1.18"
WINDOWS_BUILD = "5"
VERSION_LABEL = f"{MARKETING_VERSION}+{WINDOWS_BUILD}"
SCHEMA_VERSION = 1
APP_NAME = "搞操作"
BUNDLE_ID = "com.gaoseries.GaoCaoZuo"
