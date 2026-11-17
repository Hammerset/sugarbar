#!/usr/bin/env bash
# Render the Sugarbar app icon: packaging/AppIcon.icns for macOS and the iOS AppIcon set
# (light, dark and tinted appearances). Run from anywhere: packaging/icon/build-icons.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="../AppIcon.icns"
IOS="../../Sources/SugarbarIOS/Assets.xcassets/AppIcon.appiconset"
BIN="$(mktemp -d)/iconrender"
swiftc -O main.swift helpers.swift drawicon.swift -o "$BIN"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

"$BIN" "$ICONSET/icon_16x16.png"      16
"$BIN" "$ICONSET/icon_16x16@2x.png"   32
"$BIN" "$ICONSET/icon_32x32.png"      32
"$BIN" "$ICONSET/icon_32x32@2x.png"   64
"$BIN" "$ICONSET/icon_128x128.png"    128
"$BIN" "$ICONSET/icon_128x128@2x.png" 256
"$BIN" "$ICONSET/icon_256x256.png"    256
"$BIN" "$ICONSET/icon_256x256@2x.png" 512
"$BIN" "$ICONSET/icon_512x512.png"    512
"$BIN" "$ICONSET/icon_512x512@2x.png" 1024

iconutil -c icns "$ICONSET" -o "$OUT"
echo "OK: $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

"$BIN" "$IOS/AppIcon.png"        1024 light  --full-bleed
"$BIN" "$IOS/AppIcon-dark.png"   1024 dark   --full-bleed
"$BIN" "$IOS/AppIcon-tinted.png" 1024 tinted --full-bleed
echo "OK: $(cd "$IOS" && pwd)"
