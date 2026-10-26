#!/bin/zsh
set -euo pipefail

# 二次开发 / 重新打包时按需修改这些常量。
BUNDLE_ID="com.spultra.macos"
MARKETING_VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="15.0"

ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="$ROOT_DIR/dist"
FINAL_APP="$OUTPUT_DIR/SP Ultra.app"
APP_DIR="$ROOT_DIR/.build/package/SP Ultra.app"
ICON_SOURCE="$ROOT_DIR/Resources/ThirdParty/arrows-transfer-up-down.svg"
ICON_PNG="$ROOT_DIR/.build/SPUltraIcon-1024.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"

cd "$ROOT_DIR"
swift build -c release --arch arm64
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$ICONSET_DIR"
cp "$BUILD_DIR/SPUltra" "$APP_DIR/Contents/MacOS/SPUltra"
cp "$BUILD_DIR/SPUltraMCP" "$APP_DIR/Contents/MacOS/SPUltraMCP"
chmod 755 "$APP_DIR/Contents/MacOS/SPUltra"
chmod 755 "$APP_DIR/Contents/MacOS/SPUltraMCP"
for resource_bundle in "$BUILD_DIR"/*.bundle(N); do
    cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done

xcrun swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICON_SOURCE" "$ICON_PNG"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/MCP_SETUP.md" "$APP_DIR/Contents/Resources/MCP_SETUP.md"
mkdir -p "$APP_DIR/Contents/Resources/Licenses"
cp "$ROOT_DIR/.build/checkouts/Citadel/LICENSE" "$APP_DIR/Contents/Resources/Licenses/Citadel-LICENSE.txt"
cp "$ROOT_DIR/.build/checkouts/swift-nio-ssh/LICENSE.txt" "$APP_DIR/Contents/Resources/Licenses/swift-nio-ssh-LICENSE.txt"
cp "$ROOT_DIR/.build/checkouts/swift-nio/LICENSE.txt" "$APP_DIR/Contents/Resources/Licenses/swift-nio-LICENSE.txt"
cp "$ROOT_DIR/.build/checkouts/swift-crypto/LICENSE.txt" "$APP_DIR/Contents/Resources/Licenses/swift-crypto-LICENSE.txt"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

codesign --force --deep --sign - "$APP_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$FINAL_APP"
mv "$APP_DIR" "$FINAL_APP"
echo "$FINAL_APP"
