#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
if [[ "${1:-}" != '--run' ]]; then
  print 'Use --run [--synthetic-media] after the coordinator grants the build queue. Requires GAO_BUILD_LEASE_OWNER and GAO_BUILD_LEASE_TOKEN for the current lease.'
  exit 0
fi
shift
: "${GAO_BUILD_LEASE_OWNER:?Current build lease owner is required}"
: "${GAO_BUILD_LEASE_TOKEN:?Current build lease token is required}"
python3 - "$PROJECT_DIR/../合并迁移-2026-11-02/build.lock/owner.json" <<'PY'
import json, os, secrets, sys
from pathlib import Path
lease = json.loads(Path(sys.argv[1]).read_text())
if lease['owner'] != os.environ['GAO_BUILD_LEASE_OWNER'] or not secrets.compare_digest(lease['token'], os.environ['GAO_BUILD_LEASE_TOKEN']):
    raise SystemExit('Exact current build lease owner/token required; not compiling')
PY
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="GaoCaoZuo-ScreenshotEngine-", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Sources" "$STAGING/Tests"
SOURCE_FILES=("$PROJECT_DIR"/Sources/Screenshot*.swift)
for file in "${SOURCE_FILES[@]}"; do
  case "${file:t}" in
    ScreenshotApp.swift|ScreenshotAppActions.swift|ScreenshotMainView.swift|ScreenshotOCRView.swift|ScreenshotRecordingView.swift|ScreenshotSettingsView.swift|ScreenshotExchangeController.swift|ScreenshotHostController.swift) continue ;;
  esac
  cp "$file" "$STAGING/Sources/"
done
cp "$PROJECT_DIR/Sources/HostedInputGeneration.swift" "$STAGING/Sources/"
cp "$PROJECT_DIR"/Tests/ScreenshotEngine/*.swift "$STAGING/Tests/"
# Freeze the exact source set; compiling types does not instantiate an App or View.
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
  -D SCREENSHOT_ENGINE_TESTS -D RECORDING_SESSION_TESTS -D SCROLL_INPUT_POLICY_TESTS \
  -D SCROLL_PIXEL_EVENT_BUNDLE_TESTS -D LONG_CAPTURE_WINDOW_CROP_TESTS -D LONG_CAPTURE_BACKING_BUDGET_TESTS \
  -D LONG_CAPTURE_CANCELLATION_TESTS -D SCROLL_TARGET_GUARD_TESTS -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift "$STAGING"/Tests/*.swift \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework Vision -framework VisionKit \
  -framework PDFKit -Xlinker -weak_framework -Xlinker Translation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ImageIO -framework UniformTypeIdentifiers \
  -framework CryptoKit -framework Security -framework ApplicationServices -o "$STAGING/ScreenshotEngineTests"
"$STAGING/ScreenshotEngineTests" "$@"
