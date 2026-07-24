#!/usr/bin/env bash
# Assemble build/Whispr.dmg from build/Whispr.app: drag-to-Applications installer.
# Uses create-dmg (brew) for icon layout when available; plain hdiutil otherwise.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OpenWispr.app"
DMG="build/OpenWispr.dmg"
VOL="OpenWispr"

[ -d "$APP" ] || { echo "ERROR: $APP missing — run ./build_app.sh first"; exit 1; }
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> create-dmg"
    create-dmg \
        --volname "$VOL" \
        --window-size 540 340 \
        --icon-size 110 \
        --icon "OpenWispr.app" 140 150 \
        --app-drop-link 400 150 \
        --hide-extension "OpenWispr.app" \
        "$DMG" "$APP"
else
    echo "==> hdiutil (create-dmg not installed; plain layout)"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"

# --- Notarization (activate later with a Developer ID) -----------------------
# Prereqs: SIGN_IDENTITY="Developer ID Application: <name> (<TEAMID>)",
#          notarytool keychain profile: xcrun notarytool store-credentials whispr \
#              --apple-id <appleid> --team-id <TEAMID> --password <app-specific-pw>
# Steps:
#   codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
#   ./build_dmg.sh   # rebuild DMG from the signed app
#   xcrun notarytool submit "$DMG" --keychain-profile whispr --wait
#   xcrun stapler staple "$DMG"
# ------------------------------------------------------------------------------
