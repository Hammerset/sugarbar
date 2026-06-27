#!/usr/bin/env bash
# Build a release Sugarbar.app and ad-hoc-sign it (with the App Group entitlement) for personal use.
# Not notarized / not for distribution.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Sugarbar"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"
BUILD_DIR=".build/xcode"
ENTITLEMENTS="packaging/Sugarbar.entitlements"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with 'brew install xcodegen' (the .xcodeproj is generated, not committed)." >&2
  exit 1
fi

echo "==> Generating Sugarbar.xcodeproj from project.yml"
xcodegen generate

# Build unsigned: the App Group is a restricted entitlement that xcodebuild would
# otherwise refuse to sign ad-hoc; we embed it ourselves below.
echo "==> Building release (unsigned)"
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

echo "==> Assembling ${APP}"
mkdir -p "${DIST}"
rm -rf "${APP}"
cp -R "${BUILT}" "${APP}"

echo "==> Signing (ad-hoc, with entitlements)"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP}"

echo "OK: built ${APP}"
echo "  Run it:   open ${APP}"
echo "  Install:  cp -R ${APP} /Applications/   (recommended so launch-at-login sticks)"
