#!/usr/bin/env bash
# Compile the release binary and assemble a runnable Whispr.app bundle (ad-hoc signed).
# This script IS the per-milestone compile gate — it must exit 0 before advancing.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OpenWispr"
BIN_NAME="Whispr"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/$BIN_NAME"
[ -f "$BIN" ] || { echo "ERROR: binary not found at $BIN"; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Parity fixtures drive --selftest. They ship inside the bundle so the gate works on an
# installed copy, not only from a checkout. The Rust core reads the same files.
cp -R core/fixtures "$APP_BUNDLE/Contents/Resources/fixtures"
cp THIRD-PARTY.md "$APP_BUNDLE/Contents/Resources/THIRD-PARTY.md"
[ -d extensions/meet-names ] && cp -R extensions/meet-names "$APP_BUNDLE/Contents/Resources/meet-names"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Sparkle ships as a prebuilt framework; copy it in and sign it inside-out (see Muesli build_native_app.sh).
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Prefer the stable "Whispr Dev" identity: TCC grants (mic/accessibility/screen) survive
# rebuilds only when the designated requirement is stable — ad-hoc changes every build.
if security find-identity -p codesigning 2>/dev/null | grep -q "Whispr Dev"; then
    echo "==> codesign (Whispr Dev)"
    FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    for x in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; do
        codesign --force --sign "Whispr Dev" "$x"
    done
    codesign --force --deep --sign "Whispr Dev" "$APP_BUNDLE"
else
    echo "==> ad-hoc codesign (grants will NOT survive rebuilds)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> done: $APP_BUNDLE"
