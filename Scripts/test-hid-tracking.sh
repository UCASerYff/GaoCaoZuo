#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
TEST_ROOT=$(mktemp -d /private/tmp/gaocaozuo-tracking.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
STAGING="$TEST_ROOT/Build.noindex"
mkdir "$STAGING"
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Shared" "$STAGING/Shared"
cp "$PROJECT_DIR/Tests/HIDTrackingTuningTests.swift" "$STAGING/HIDTrackingTuningTests.swift"
rm "$STAGING/Sources/App.swift"
cat > "$STAGING/Main.swift" <<'SWIFT'
import Foundation
import Darwin
@main enum HIDTrackingTestMain {
    @MainActor static func main() {
        do {try runHIDTrackingTuningTests()}
        catch {FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8));exit(1)}
    }
}
SWIFT
# Compile a production-source snapshot, then run only the injected transaction
# backend. No live IOHID parameter writes, window, event tap, or smoke launch.
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
  -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$STAGING"/Shared/*.swift \
  "$STAGING/HIDTrackingTuningTests.swift" "$STAGING/Main.swift" \
  -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
  -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
  -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN -o "$STAGING/tests"
"$STAGING/tests" --data-dir "$STAGING/data"
