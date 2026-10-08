#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
STAGING=$(mktemp -d /private/tmp/gaocaozuo-tests.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
python3 -B "$PROJECT_DIR/Tests/InstallTests.py"
swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Tests/IconTests.swift" "$PROJECT_DIR/Assets/AppIcon.png"
if [[ -f "$PROJECT_DIR/Tests/TestMain.swift" ]]; then
  ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
  rm "$STAGING/Sources/App.swift"
  TEST_FILES=("$PROJECT_DIR"/Tests/*.swift)
  TEST_FILES=("${(@)TEST_FILES:#*/IconTests.swift}")
  swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
    -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "${TEST_FILES[@]}" \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
    -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
    -framework IOKit -framework Security -framework ImageIO -o "$STAGING/tests"
  "$STAGING/tests" --data-dir "$STAGING/data" --engine "$PROJECT_DIR/Resources/Tools/7zz"
else
  print '尚无 Tests/TestMain.swift，已完成独立安装与图标测试。'
fi
