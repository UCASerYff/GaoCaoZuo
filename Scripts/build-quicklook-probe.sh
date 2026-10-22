#!/bin/zsh
# Builds a private uniquely identified sandbox probe. Does not register or open it.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ $# == 1 && "$1" == /*.noindex && ! -e "$1" ]] || {print -u2 'Provide a new absolute .noindex directory';exit 1;}
PROBE_ROOT="$1"
HOST="$PROBE_ROOT/GaoQuickLookProbe.app"
EXT="$HOST/Contents/PlugIns/GaoQuickLookHelperProbe.appex"
TOOLS="$EXT/Contents/Resources/Tools"
XPC="$EXT/Contents/XPCServices/SandboxProbe.xpc"
BROKER="$EXT/Contents/XPCServices/BrokerProbe.xpc"
mkdir -p "$HOST/Contents/MacOS" "$EXT/Contents/MacOS" "$TOOLS" "$PROBE_ROOT/cache"
ditto "$PROJECT_DIR/Sources" "$PROBE_ROOT/Sources"
ditto "$PROJECT_DIR/Shared" "$PROBE_ROOT/Shared"
ditto "$PROJECT_DIR/QuickLookExtension" "$PROBE_ROOT/QuickLookExtension"
cp "$PROJECT_DIR/Scripts/QuickLookArchiveEditMain.swift" "$PROBE_ROOT/HelperMain.swift"
cp "$PROJECT_DIR/Tests/QuickLookProbe/ProbeController.swift" "$PROBE_ROOT/ProbeController.swift"
cp "$PROJECT_DIR/Tests/QuickLookProbe/SandboxProbeProtocol.swift" "$PROBE_ROOT/SandboxProbeProtocol.swift"
cp "$PROJECT_DIR/Tests/QuickLookProbe/SandboxProbeMain.swift" "$PROBE_ROOT/SandboxProbeMain.swift"
cp "$PROJECT_DIR/Tests/QuickLookProbe/BrokerProbeMain.swift" "$PROBE_ROOT/BrokerProbeMain.swift"
cp "$PROJECT_DIR/Tests/QuickLookProbe/IOBoundaryProbe.c" "$PROBE_ROOT/IOBoundaryProbe.c"
cp "$PROJECT_DIR/Tests/QuickLookProbe/InvalidCaller.swift" "$PROBE_ROOT/InvalidCaller.swift"
ditto "$PROJECT_DIR/Resources/Tools" "$TOOLS"
SDK=$(xcrun --sdk macosx --show-sdk-path)
HELPER_SOURCES=("$PROBE_ROOT"/Sources/*.swift)
HELPER_SOURCES=("${(@)HELPER_SOURCES:#*/App.swift}")
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$PROBE_ROOT/cache" \
  "${HELPER_SOURCES[@]}" "$PROBE_ROOT"/Shared/*.swift "$PROBE_ROOT/HelperMain.swift" \
  -framework FinderSync -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
  -framework ApplicationServices -framework Carbon -framework CoreImage -framework ServiceManagement -framework IOKit \
  -framework Security -framework ImageIO -framework Quartz -framework CoreWLAN -o "$EXT/Contents/MacOS/QuickLookArchiveEdit"
mkdir -p "$XPC/Contents/MacOS"
cp "$TOOLS/7zz" "$XPC/Contents/MacOS/7zz"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$PROBE_ROOT/cache" \
  "$PROBE_ROOT/SandboxProbeProtocol.swift" "$PROBE_ROOT/SandboxProbeMain.swift" \
  -framework Foundation -framework Security -framework CryptoKit -o "$XPC/Contents/MacOS/SandboxProbe"
mkdir -p "$BROKER/Contents/MacOS"
cp "$TOOLS/7zz" "$BROKER/Contents/MacOS/7zz"
xcrun clang "$PROBE_ROOT/IOBoundaryProbe.c" -o "$BROKER/Contents/MacOS/IOBoundaryProbe"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$PROBE_ROOT/cache" \
  "$PROBE_ROOT/SandboxProbeProtocol.swift" "$PROBE_ROOT/Shared/QuickLookArchiveEditProtocol.swift" "$PROBE_ROOT/BrokerProbeMain.swift" \
  -framework Foundation -framework Security -framework CryptoKit -o "$BROKER/Contents/MacOS/BrokerProbe"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$PROBE_ROOT/cache" \
  "$PROBE_ROOT/SandboxProbeProtocol.swift" "$PROBE_ROOT/InvalidCaller.swift" \
  -framework Foundation -framework Security -o "$EXT/Contents/MacOS/InvalidProbeCaller"
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$PROBE_ROOT/cache" \
  -module-name GaoQuickLookHelperProbe -application-extension -emit-executable -Xlinker -e -Xlinker _NSExtensionMain \
  "$PROBE_ROOT"/QuickLookExtension/*.swift "$PROBE_ROOT/Shared/GaoLocalization.swift" "$PROBE_ROOT/Shared/QuickLookArchiveEditProtocol.swift" \
  "$PROBE_ROOT/ProbeController.swift" "$PROBE_ROOT/SandboxProbeProtocol.swift" -framework AppKit -framework QuickLookUI -framework PDFKit -framework ImageIO -framework CryptoKit -framework Security -o "$EXT/Contents/MacOS/GaoQuickLookHelperProbe"
print 'int main(void) { return 0; }' | xcrun clang -x c - -o "$HOST/Contents/MacOS/ProbeHost"
python3 - "$PROJECT_DIR" "$HOST" "$EXT" "$XPC" "$PROBE_ROOT" "$BROKER" <<'PY'
import sys,plistlib,subprocess
from pathlib import Path
project,host,extension,xpc,root,broker=map(Path,sys.argv[1:]);uti='com.gaoseries.gaocaozuo.private-ql-probe'
info={'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.QuickLookProbeHost','CFBundleName':'GaoQuickLookProbe','CFBundleExecutable':'ProbeHost','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.01','CFBundleVersion':'1','LSUIElement':True,'UTExportedTypeDeclarations':[{'UTTypeIdentifier':uti,'UTTypeConformsTo':['public.data'],'UTTypeTagSpecification':{'public.filename-extension':['gaoqlprobe']}}],'CFBundleDocumentTypes':[{'CFBundleTypeRole':'Viewer','LSItemContentTypes':[uti],'LSHandlerRank':'Owner'}]}
(host/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run([sys.executable,str(project/'Scripts/make_plist.py'),str(extension/'Contents/Info.plist'),'0.01','1','--quicklook'],check=True)
info=plistlib.loads((extension/'Contents/Info.plist').read_bytes());info['CFBundleIdentifier']='com.gaoseries.GaoCaoZuo.QuickLookHelperProbe';info['CFBundleExecutable']='GaoQuickLookHelperProbe';info['NSExtension']['NSExtensionPrincipalClass']='GaoQuickLookHelperProbeController';info['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']=[uti]
(extension/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(xpc/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.QuickLookHelperProbe.SandboxProbe','CFBundleExecutable':'SandboxProbe','CFBundlePackageType':'XPC!','CFBundleVersion':'1','XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}))
(root/'xpc.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True}))
(broker/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCaoZuo.QuickLookHelperProbe.BrokerProbe','CFBundleExecutable':'BrokerProbe','CFBundlePackageType':'XPC!','CFBundleVersion':'1','XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}))
PY
python3 "$PROJECT_DIR/Scripts/prepare-localizations.py" "$EXT/Contents/Resources"
while IFS= read -r -d '' native; do
  if /usr/bin/file -b "$native" | /usr/bin/grep -q 'Mach-O';then codesign --force --sign - --timestamp=none "$native";fi
done < <(find "$TOOLS" -type f -print0)
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.QuickLookArchiveEdit --entitlements "$PROJECT_DIR/QuickLookExtension/QuickLookEditHelper.entitlements" "$EXT/Contents/MacOS/QuickLookArchiveEdit"
codesign --force --sign - --timestamp=none "$XPC/Contents/MacOS/7zz"
codesign --force --sign - --timestamp=none --entitlements "$PROBE_ROOT/xpc.entitlements" "$XPC"
codesign --force --sign - --timestamp=none "$BROKER/Contents/MacOS/7zz"
codesign --force --sign - --timestamp=none "$BROKER/Contents/MacOS/IOBoundaryProbe"
codesign --force --sign - --timestamp=none "$BROKER"
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.QuickLookHelperProbe "$EXT/Contents/MacOS/InvalidProbeCaller"
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.QuickLookHelperProbe --entitlements "$PROJECT_DIR/QuickLookExtension/QuickLook.entitlements" "$EXT"
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.QuickLookProbeHost "$HOST"
codesign --verify --deep --strict "$HOST"
print "PROBE=$HOST"
