#!/usr/bin/env bash
# Build a release binary and wrap it in an ad-hoc-signed Sugarbar.app for personal use.
# Not notarized / not for distribution.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Sugarbar"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"

echo "==> Building release..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
cp packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "${APP}"

echo "OK: built ${APP}"
echo "  Run it:   open ${APP}"
echo "  Install:  cp -R ${APP} /Applications/   (recommended so launch-at-login sticks)"
