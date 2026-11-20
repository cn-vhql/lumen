#!/bin/bash
# Builds Lumen.app: a menu bar app plus an ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Lumen"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="local.lumen.controller"
VERSION="${LUMEN_VERSION:-1.4.0}"
# 默认同时编 arm64 与 x86_64，再用 lipo 合成通用二进制；只想要单架构可以
# LUMEN_ARCHS=arm64 ./build.sh
ARCHS="${LUMEN_ARCHS:-arm64 x86_64}"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Copying icon resources"
if [ ! -f "$ROOT/icons/AppIcon.icns" ] || [ ! -f "$ROOT/icons/menubar.png" ]; then
    echo "    icon assets missing; regenerating"
    swift "$ROOT/tools/make-icons.swift" "$ROOT/icons" warm >/dev/null
    iconutil -c icns "$ROOT/icons/AppIcon.iconset" -o "$ROOT/icons/AppIcon.icns"
fi
cp "$ROOT/icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/icons/menubar.png" "$APP/Contents/Resources/menubar.png"

echo "==> Compiling ($ARCHS)"
SLICE_DIR="$(mktemp -d)"
trap 'rm -rf "$SLICE_DIR"' EXIT
SLICES=()
for arch in $ARCHS; do
    echo "    $arch"
    swiftc \
      -O \
      -whole-module-optimization \
      -target "$arch-apple-macos13.0" \
      -framework AppKit \
      -framework Carbon \
      -framework CoreAudio \
      -framework IOKit \
      -framework ServiceManagement \
      -o "$SLICE_DIR/$APP_NAME-$arch" \
      "$ROOT"/Sources/*.swift
    SLICES+=("$SLICE_DIR/$APP_NAME-$arch")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    echo "==> Lipoing ${#SLICES[@]} slices"
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Done: $APP"
echo "    arch: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
du -sh "$APP" | awk '{print "    size:", $1}'
