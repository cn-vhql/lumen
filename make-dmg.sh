#!/bin/bash
# Builds Lumen.app and packs it into a release-ready DMG at build/Lumen-<version>.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$ROOT/build.sh"

APP="$ROOT/build/Lumen.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Lumen-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"

echo "==> Staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating Lumen-$VERSION.dmg"
rm -f "$DMG"
hdiutil create \
    -volname "Lumen" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    -ov \
    "$DMG"
rm -rf "$STAGE"

echo "==> Done: $DMG"
du -sh "$DMG" | awk '{print "    size:", $1}'
