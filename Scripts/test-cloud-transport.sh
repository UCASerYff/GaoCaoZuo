#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ $# == 1 && "$1" == /* ]] || { print -u2 'Pass an explicit iCloud Drive parent; only a new synthetic child is tested.'; exit 2; }
TEST_ROOT=$(mktemp -d /private/tmp/gaocaozuo-cloud-tests.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
STAGING="$TEST_ROOT/Build.noindex"
mkdir -p "$STAGING/Tests.app/Contents/MacOS"
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Shared" "$STAGING/Shared"
ditto "$PROJECT_DIR/Tests/InputCloudTransportTests.swift" "$STAGING/InputCloudTransportTests.swift"
ditto "$PROJECT_DIR/Tests/CloudTransport/Main.swift" "$STAGING/Main.swift"
rm "$STAGING/Sources/App.swift"
python3 "$PROJECT_DIR/Scripts/prepare-localizations.py" "$STAGING/Tests.app/Contents/Resources"
python3 - "$STAGING/Tests.app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.CloudTests','CFBundleExecutable':'tests','CFBundlePackageType':'APPL','LSUIElement':True,'CFBundleDevelopmentRegion':'zh-Hans'}))
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
  -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$STAGING"/Shared/*.swift \
  "$STAGING/InputCloudTransportTests.swift" "$STAGING/Main.swift" \
  -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
  -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
  -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN \
  -o "$STAGING/Tests.app/Contents/MacOS/tests"
"$STAGING/Tests.app/Contents/MacOS/tests" "$1"
