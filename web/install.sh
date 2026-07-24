#!/bin/sh
# Whispr installer — downloads the latest release, installs to /Applications,
# and removes the quarantine flag so Gatekeeper does not block the unsigned build.
# Usage: curl -fsSL https://whispr-black-chi.vercel.app/install.sh | sh
set -eu

ZIP_URL="https://github.com/SirCharan/whispr/releases/latest/download/Whispr.zip"
DEST="/Applications/Whispr.app"

echo "==> Whispr installer"

# Apple Silicon only (WhisperKit needs the Neural Engine)
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: Whispr requires an Apple Silicon Mac (this machine is $(uname -m))." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading latest release…"
curl -fsSL -o "$TMP/Whispr.zip" "$ZIP_URL"

echo "==> unpacking…"
ditto -xk "$TMP/Whispr.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/Whispr.app" ] || { echo "ERROR: unexpected archive layout" >&2; exit 1; }

# stop a running copy and replace the old install
pkill -f "Whispr.app/Contents/MacOS/Whispr" 2>/dev/null || true
sleep 1
rm -rf "$DEST"

echo "==> installing to /Applications…"
ditto "$TMP/unpacked/Whispr.app" "$DEST"

echo "==> removing quarantine flag…"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# fresh install = fresh onboarding
defaults delete com.ck.whispr onboarded 2>/dev/null || true

echo "==> launching…"
open "$DEST"

echo ""
echo "Done — Whispr is running. No window opens: look for the MICROPHONE ICON"
echo "in your menu bar (top-right, near the clock). Click it for status."
echo "First run: a setup wizard appears and downloads the speech model (~1.5 GB, once)."
echo "Dictate anywhere: hold Cmd+Shift+D, speak, release."
