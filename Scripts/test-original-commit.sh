#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
TEST_ROOT=$(mktemp -d /private/tmp/gaocaozuo-original-tests.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
STAGING="$TEST_ROOT/Build.noindex"
mkdir -p "$STAGING"
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Shared" "$STAGING/Shared"
cp "$PROJECT_DIR/Tests/ArchiveOriginalCommitTests.swift" "$STAGING/ArchiveOriginalCommitTests.swift"
rm "$STAGING/Sources/App.swift"
cat > "$STAGING/Main.swift" <<'SWIFT'
import Foundation
import Darwin
@main enum OriginalCommitTestMain {
 @MainActor static func main() async {
  setbuf(stdout,nil);GaoLocale.shared.setLanguage(.zhHans)
  do {try await runArchiveOriginalCommitTests(engine:URL(fileURLWithPath:CommandLine.arguments[1]))}
  catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
 }
}
SWIFT
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
 -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$STAGING"/Shared/*.swift "$STAGING/ArchiveOriginalCommitTests.swift" "$STAGING/Main.swift" \
 -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
 -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement \
 -framework IOKit -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN -o "$STAGING/tests"
"$STAGING/tests" "$PROJECT_DIR/Resources/Tools/7zz"
