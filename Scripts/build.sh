#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
APP_VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUILD_NUMBER=$(tr -d '\n' < "$PROJECT_DIR/BUILD")
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || { print -u2 '版本或构建号无效'; exit 1; }
if [[ $# != 0 ]]; then
  [[ $# == 2 && "$1" == '--app-only' && "$2" == /* && "$2" == *.app && ! -e "$2" ]] || { print -u2 '用法：build.sh [--app-only <不存在的绝对路径.app>]'; exit 1; }
fi
STAGING=$(mktemp -d /private/tmp/gaocaozuo-build.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/搞操作.app"
EXT="$APP/Contents/PlugIns/GaoFinderSync.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/FinderExtension" "$STAGING/FinderExtension"
if [[ ! -f "$PROJECT_DIR/Assets/AppIcon.png" || "$PROJECT_DIR/Assets/Lettering.png" -nt "$PROJECT_DIR/Assets/AppIcon.png" || "$PROJECT_DIR/Scripts/ComposeIcon.swift" -nt "$PROJECT_DIR/Assets/AppIcon.png" ]]; then
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/ComposeIcon.swift" "$PROJECT_DIR/Assets/Lettering.png" "$PROJECT_DIR/Assets/AppIcon.png"
fi
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers \
  -framework CryptoKit -framework ApplicationServices -framework Carbon -framework CoreImage \
  -framework ServiceManagement -framework IOKit -framework Security -framework ImageIO -o "$APP/Contents/MacOS/GaoCaoZuo"
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  -module-name GaoFinderSync -application-extension -emit-executable -Xlinker -e -Xlinker _NSExtensionMain \
  "$STAGING"/FinderExtension/*.swift -framework AppKit -framework FinderSync -o "$EXT/Contents/MacOS/GaoFinderSync"
if [[ ! -f "$PROJECT_DIR/Assets/AppIcon.icns" || "$PROJECT_DIR/Assets/AppIcon.png" -nt "$PROJECT_DIR/Assets/AppIcon.icns" ]]; then
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR/Assets/AppIcon.png" "$PROJECT_DIR/Assets/AppIcon.icns"
fi
ditto "$PROJECT_DIR/Resources" "$APP/Contents/Resources"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
[[ ! -f "$PROJECT_DIR/使用说明.txt" ]] || cp "$PROJECT_DIR/使用说明.txt" "$APP/Contents/Resources/使用说明.txt"
ditto "$PROJECT_DIR/Docs" "$APP/Contents/Resources/Docs"
python3 "$PROJECT_DIR/Scripts/make_plist.py" "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER"
python3 "$PROJECT_DIR/Scripts/make_plist.py" "$EXT/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER" --extension
plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist"
if [[ -f "$APP/Contents/Resources/Tools/7zz" ]]; then
  chmod 755 "$APP/Contents/Resources/Tools/7zz"
  codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.7zz "$APP/Contents/Resources/Tools/7zz"
fi
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo.FinderSync --entitlements "$PROJECT_DIR/Resources/FinderSync.entitlements" "$EXT"
codesign --force --sign - --timestamp=none --identifier com.gaoseries.GaoCaoZuo "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${1:-}" == '--app-only' ]]; then
  ditto "$APP" "$2"
  print "APP=$2"
  exit 0
fi
mkdir -p "$STAGING/disk" "$PROJECT_DIR/Release"
ditto "$APP" "$STAGING/disk/搞操作.app"
ln -s /Applications "$STAGING/disk/Applications"
[[ ! -f "$PROJECT_DIR/使用说明.txt" ]] || cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞操作 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoCaoZuo-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoCaoZuo-$APP_VERSION.dmg"
mv "$STAGING/GaoCaoZuo-$APP_VERSION.dmg" "$PROJECT_DIR/Release/GaoCaoZuo-$APP_VERSION.dmg"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoCaoZuo-$APP_VERSION.dmg" > "GaoCaoZuo-$APP_VERSION.dmg.sha256")
print "完成：$PROJECT_DIR/Release/GaoCaoZuo-$APP_VERSION.dmg"
