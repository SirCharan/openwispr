#!/bin/sh
# OpenWispr installer — downloads the latest release, installs to /Applications,
# and removes the quarantine flag so Gatekeeper does not block the unsigned build.
# Usage: curl -fsSL https://openwispr.vercel.app/install.sh | sh
set -eu

ZIP_URL="https://github.com/SirCharan/openwispr/releases/latest/download/OpenWispr.zip"
DEST="/Applications/OpenWispr.app"

echo "==> OpenWispr installer"

# Apple Silicon only (WhisperKit needs the Neural Engine)
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: OpenWispr requires an Apple Silicon Mac (this machine is $(uname -m))." >&2
    exit 1
fi

FRESH=1
[ -d "$DEST" ] && FRESH=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading latest release…"
curl -fsSL -o "$TMP/OpenWispr.zip" "$ZIP_URL"

echo "==> unpacking…"
ditto -xk "$TMP/OpenWispr.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/OpenWispr.app" ] || { echo "ERROR: unexpected archive layout" >&2; exit 1; }

# stop a running copy and replace the old install
pkill -f "Wispr.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$DEST"

echo "==> installing to /Applications…"
ditto "$TMP/unpacked/OpenWispr.app" "$DEST"

echo "==> removing quarantine flag…"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# fresh install = fresh onboarding; updates keep the user's completed state
[ "$FRESH" = "1" ] && defaults delete org.openwispr.app onboarded 2>/dev/null || true

echo "==> launching…"
open "$DEST"

echo ""
echo "Done — OpenWispr is running and the setup wizard is on your screen."
echo "It walks you through permissions and the speech-model download (~1.5 GB, once)."
echo "After setup: hold the fn key anywhere, speak, release — your words paste."
echo "OpenWispr also lives in your menu bar (microphone icon, top-right)."
