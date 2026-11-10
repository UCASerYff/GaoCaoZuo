#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}

# Compilation is explicit and never acquires the shared heavy-build lease.
if [[ ${1:-} == --build-cli || ${1:-} == --build-tests ]]; then
  mode=$1
  shift
  [[ $# == 1 && $1 == /* && $1 == *.noindex/* ]] || { print -u2 '编译需要 .noindex 容器中的绝对输出文件路径'; exit 2; }
  output=$1
  /usr/bin/python3 - "$PROJECT_DIR/../合并迁移-2026-11-02/build_lease.py" "$output" <<'PY'
import os, pathlib, runpy, secrets, stat, sys
lease = runpy.run_path(sys.argv[1])['read_lease']()
owner = os.environ.get('GAO_BUILD_LEASE_OWNER')
token = os.environ.get('GAO_BUILD_LEASE_TOKEN')
if not lease or not owner or not token or lease.get('owner') != owner or not secrets.compare_digest(lease.get('token', ''), token):
    raise SystemExit('编译仅可使用总协调持有的准确租约；不会自动获取、抢占或释放租约')
output = pathlib.Path(sys.argv[2])
if not output.is_absolute() or any(p in ('.', '..') for p in output.parts) or not any(p.endswith('.noindex') for p in output.parent.parts):
    raise SystemExit('输出必须位于绝对 .noindex 容器')
current = pathlib.Path('/')
for part in output.parent.parts[1:]:
    current /= part
    try:
        info = current.lstat()
    except FileNotFoundError:
        current.mkdir(mode=0o700)
        info = current.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise SystemExit('输出父路径含链接或非目录，已停止')
if output.exists() or output.is_symlink():
    raise SystemExit('输出路径已存在；请使用新的输出路径')
PY
  sources=("$PROJECT_DIR"/Sources/*.swift)
  sources=("${(@)sources:#*/App.swift}")
  if [[ $mode == --build-cli ]]; then
    define=LEGACY_DESKTOP_RETIREMENT_CLI
  else
    define=LEGACY_DESKTOP_RETIREMENT_TESTS
    sources+=("$PROJECT_DIR/Tests/LegacyDesktopRetirementTests.swift")
  fi
  /usr/bin/xcrun swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -D "$define" \
    -module-cache-path "${output:h}/ModuleCache.noindex" "${sources[@]}" "$PROJECT_DIR"/Shared/*.swift \
    -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
    -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
    -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN -framework ScreenCaptureKit \
    -framework AVFoundation -framework AVKit -framework Vision -framework PDFKit -framework Accelerate -o "$output"
  print "$output"
  exit
fi

[[ -n ${LEGACY_DESKTOP_RETIREMENT_CLI:-} && $LEGACY_DESKTOP_RETIREMENT_CLI == /* && -x $LEGACY_DESKTOP_RETIREMENT_CLI ]] || {
  print -u2 '请设置 LEGACY_DESKTOP_RETIREMENT_CLI 为总协调租约下编译的薄 CLI；本脚本不会自动编译或运行测试'
  exit 2
}
exec "$LEGACY_DESKTOP_RETIREMENT_CLI" "$@"
