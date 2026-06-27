#!/usr/bin/env bash
# Render the Sugarbar app icon at every iconset size and assemble packaging/AppIcon.icns.
# Run from anywhere: packaging/icon/build-icns.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="../AppIcon.icns"
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
