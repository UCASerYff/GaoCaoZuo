#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
STAGING=$(mktemp -d /private/tmp/gaocaozuo-tests.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Tests.app/Contents/MacOS"
python3 "$PROJECT_DIR/Scripts/prepare-localizations.py" "$STAGING/Tests.app/Contents/Resources"
python3 - "$STAGING/Tests.app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.Tests','CFBundleExecutable':'tests','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'zh-Hans','CFBundleLocalizations':['zh-Hans','en','ja','de','fr','es','ko','pt']}))
PY
python3 -B "$PROJECT_DIR/Tests/InstallTests.py"
python3 -B "$PROJECT_DIR/Tests/TemplateAssetTests.py"
python3 -B "$PROJECT_DIR/Tests/FinderCallbackTests.py"
python3 -B "$PROJECT_DIR/Tests/QuickLookResourceTests.py"
python3 -B "$PROJECT_DIR/Tests/QuickLookPreflightTests.py"
swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Tests/IconTests.swift" "$PROJECT_DIR/Assets/AppIcon.png"
if [[ -f "$PROJECT_DIR/Tests/TestMain.swift" ]]; then
  ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
  ditto "$PROJECT_DIR/Shared" "$STAGING/Shared"
  rm "$STAGING/Sources/App.swift"
  TEST_FILES=("$PROJECT_DIR"/Tests/*.swift)
  TEST_FILES=("${(@)TEST_FILES:#*/IconTests.swift}")
  swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
    -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$STAGING"/Shared/*.swift "${TEST_FILES[@]}" \
    -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
    -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
    -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN -o "$STAGING/Tests.app/Contents/MacOS/tests"
  "$STAGING/Tests.app/Contents/MacOS/tests" --data-dir "$STAGING/data" --engine "$PROJECT_DIR/Resources/Tools/7zz"
else
  print '尚无 Tests/TestMain.swift，已完成独立安装与图标测试。'
fi
