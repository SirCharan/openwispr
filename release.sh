#!/usr/bin/env bash
# Usage: ./release.sh X.Y.Z [--dry-run]
# Bumps version, builds, zips, DMG, appcast item, cask sha. Without --dry-run also commits, pushes, publishes.
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?usage: release.sh X.Y.Z [--dry-run]}"; DRY="${2:-}"
security find-identity -p codesigning | grep -q "Whispr Dev" || { echo "ERROR: Whispr Dev signing identity missing"; exit 1; }
IFS=. read -r MA MI PA <<<"$VER"; BUILD=$((MI*100+PA))
PL=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$PL"

mkdir -p web/release-notes
NOTES="web/release-notes/$VER.md"
if [ ! -f "$NOTES" ]; then  # CHANGELOG section for this version
  awk -v v="$VER" '/^## /{p=index($0,v)>0; next} p' CHANGELOG.md > "$NOTES"
  [ -s "$NOTES" ] || echo "Release $VER" > "$NOTES"
fi
grep -q "^## \[\?$VER" CHANGELOG.md || printf '\n## %s\n- Release %s\n' "$VER" "$VER" >> CHANGELOG.md

./build_app.sh
build/OpenWispr.app/Contents/MacOS/OpenWispr --selftest
rm -f build/OpenWispr.zip
ditto -c -k --keepParent build/OpenWispr.app build/OpenWispr.zip
./build_dmg.sh

PFX="https://github.com/SirCharan/openwispr/releases/download/v$VER"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
cp build/OpenWispr.zip "$SCRATCH/"; cp "$NOTES" "$SCRATCH/OpenWispr.md"
GEN=.build/artifacts/sparkle/Sparkle/bin/generate_appcast
"$GEN" --download-url-prefix "$PFX/" --embed-release-notes "$SCRATCH"
python3 Tools/merge_appcast_item.py --existing web/appcast.xml --generated "$SCRATCH/appcast.xml" \
  --build "$BUILD" --url "$PFX/OpenWispr.zip"

SHA="$(shasum -a 256 build/OpenWispr.zip | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$VER\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" packaging/openwispr.rb

if [ "$DRY" = "--dry-run" ]; then echo "dry run done: zip, dmg, appcast item, cask sha $SHA"; exit 0; fi

git add -A && git reset -q build target .build .grind.log 2>/dev/null || true
git commit -m "chore: release $VER"
git push origin master
gh release create "v$VER" build/OpenWispr.zip build/OpenWispr.dmg --notes-file "$NOTES"
(cd web && vercel --prod --yes)
echo "Update the tap: copy packaging/openwispr.rb to SirCharan/homebrew-openwispr Casks/openwispr.rb and push."
