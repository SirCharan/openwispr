#!/usr/bin/env bash
# Compile the release binary and assemble a runnable Whispr.app bundle (ad-hoc signed).
# This script IS the per-milestone compile gate — it must exit 0 before advancing.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Whispr"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/$APP_NAME"
[ -f "$BIN" ] || { echo "ERROR: binary not found at $BIN"; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc signature so the bundle runs locally and TCC (mic/accessibility) grants persist.
echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
