#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
# Compilation is opt-in and requires the coordinator's current exact heavy-build lease.
if [[ ${1:-} == --build-cli || ${1:-} == --build-tests || ${1:-} == --build-history-tests ]]; then
  mode=$1
  shift
  [[ $# == 1 && $1 == /* && $1 == *.noindex/* ]] || { print -u2 '编译需要.noindex容器中的绝对输出路径'; exit 2; }
  output=$1
  /usr/bin/python3 - "$PROJECT_DIR/../合并迁移-2026-11-02/build.lock/owner.json" <<'PY'
import json, os, pathlib, secrets, sys
lease = json.loads(pathlib.Path(sys.argv[1]).read_text())
owner, token = os.environ.get('GAO_BUILD_LEASE_OWNER'), os.environ.get('GAO_BUILD_LEASE_TOKEN')
if not owner or not token or lease.get('owner') != owner or not secrets.compare_digest(lease.get('token', ''), token):
    raise SystemExit('编译仅可使用总协调持有的准确租约；不会自动抢占或获取租约')
PY
  mkdir -p "${output:h}"
  sources=("$PROJECT_DIR"/Sources/ScreenshotMigration*.swift)
  if [[ $mode == --build-cli ]]; then
    define=SCREENSHOT_MIGRATION_CLI
  elif [[ $mode == --build-tests ]]; then
    define=SCREENSHOT_MIGRATION_TESTS
    sources+=("$PROJECT_DIR/Sources/ScreenshotDataBackup.swift" "$PROJECT_DIR/Tests/ScreenshotMigrationMain.swift" "$PROJECT_DIR/Tests/ScreenshotMigrationActivityTests.swift" "$PROJECT_DIR/Tests/ScreenshotMigrationHistoryPolicyTests.swift")
  else
    define=SCREENSHOT_MIGRATION_HISTORY_TESTS
    sources+=("$PROJECT_DIR/Sources/ScreenshotDataBackup.swift" "$PROJECT_DIR/Tests/ScreenshotMigrationHistoryPolicyTests.swift")
  fi
  /usr/bin/xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -D "$define" \
    -module-cache-path "${output:h}/ModuleCache.noindex" "${sources[@]}" -o "$output"
  print "$output"
  exit
fi
[[ -n ${SCREENSHOT_MIGRATION_CLI:-} && -x $SCREENSHOT_MIGRATION_CLI ]] || { print -u2 '请设置SCREENSHOT_MIGRATION_CLI为总协调租约下编译的薄CLI；本脚本不会自动编译或触碰资料'; exit 2; }
exec "$SCREENSHOT_MIGRATION_CLI" "$@"
