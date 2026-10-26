#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP="$ROOT_DIR/dist/SP Ultra.app"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found; building it first…"
    zsh "$ROOT_DIR/scripts/package-app.sh"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT_DIR/SPUltra-${VERSION}-arm64.dmg"

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/spultra-dmg.XXXXXX")
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

ditto "$APP" "$STAGING/SP Ultra.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "SP Ultra" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "$DMG"
