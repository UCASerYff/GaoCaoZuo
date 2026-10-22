#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ $# == 0 ]] || { print -u2 'No arguments: a new private synthetic fixture root is generated.'; exit 2; }
FIXTURE_ROOT=$(python3 - <<'PY'
import os,uuid
p='/private/tmp/gaocaozuo-acceptance-'+str(uuid.uuid4())+'.noindex'
os.mkdir(p,0o700)
print(p)
PY
)
FIXTURE_PREPARED=false
trap 'if [[ "$FIXTURE_PREPARED" == false ]]; then rm -rf "$FIXTURE_ROOT"; fi' EXIT
STAGING="$FIXTURE_ROOT/Helper.noindex"
mkdir -p "$STAGING/RichConsumer.app/Contents/MacOS"
chmod 700 "$STAGING"
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Shared" "$STAGING/Shared"
ditto "$PROJECT_DIR/Tests/RichConsumer/Main.swift" "$STAGING/Main.swift"
rm "$STAGING/Sources/App.swift"
python3 "$PROJECT_DIR/Scripts/prepare-localizations.py" "$STAGING/RichConsumer.app/Contents/Resources"
python3 - "$STAGING/RichConsumer.app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.RichConsumerFixture','CFBundleExecutable':'rich-consumer','CFBundlePackageType':'APPL','LSUIElement':True,'CFBundleDevelopmentRegion':'zh-Hans'}))
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
  -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$STAGING"/Shared/*.swift "$STAGING/Main.swift" \
  -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
  -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
  -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN \
  -o "$STAGING/RichConsumer.app/Contents/MacOS/rich-consumer"
"$STAGING/RichConsumer.app/Contents/MacOS/rich-consumer" prepare
FIXTURE_PREPARED=true
rm -rf "$STAGING/Sources" "$STAGING/Shared" "$STAGING/cache"
rm "$STAGING/Main.swift"
