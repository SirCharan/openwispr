#!/usr/bin/env bash
# Usage: ./release.sh X.Y.Z [--dry-run]
# Bumps version, builds, zips, DMG, appcast item. Without --dry-run also uploads the build to the private
# download host, commits, pushes, creates a notes-only GitHub release and publishes the appcast.
# The private host lives outside this public repo: $OPENWISPR_DIST (default ../whispr-dist) holds .token
# (the unguessable path segment), .base (the host) and public/<token>/. Never commit those values.
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?usage: release.sh X.Y.Z [--dry-run]}"; DRY="${2:-}"
DIST="${OPENWISPR_DIST:-$(cd .. && pwd)/whispr-dist}"
[ -s "$DIST/.token" ] && [ -s "$DIST/.base" ] || { echo "ERROR: private host config missing in $DIST (.token, .base)"; exit 1; }
DIST_URL="https://$(cat "$DIST/.base")/$(cat "$DIST/.token")"; DIST_DIR="$DIST/public/$(cat "$DIST/.token")"
VERCEL_SCOPE="${OPENWISPR_VERCEL_SCOPE:-ckdeltaexchange-1648s-projects}"
security find-identity -p codesigning | grep -q "Whispr Dev\|Developer ID Application" || { echo "ERROR: no Whispr Dev or Developer ID signing identity"; exit 1; }
# Notarize only when the app is signed with a Developer ID (profile: xcrun notarytool store-credentials openwispr).
is_devid() { codesign -dv build/OpenWispr.app 2>&1 | grep -q "Authority=Developer ID Application"; }
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

OPENWISPR_RELEASE=1 ./build_app.sh
# The release build must enforce the license: fail if the source-build marker leaked in.
[ "$(/usr/libexec/PlistBuddy -c "Print :OWSourceBuild" build/OpenWispr.app/Contents/Info.plist 2>/dev/null || echo false)" != "true" ] || { echo "ERROR: release build carries OWSourceBuild=true"; exit 1; }
build/OpenWispr.app/Contents/MacOS/OpenWispr --selftest
rm -f build/OpenWispr.zip
ditto -c -k --keepParent build/OpenWispr.app build/OpenWispr.zip
if is_devid; then
  xcrun notarytool submit build/OpenWispr.zip --keychain-profile openwispr --wait
  xcrun stapler staple build/OpenWispr.app
  spctl -a -vv -t install build/OpenWispr.app
  rm -f build/OpenWispr.zip
  ditto -c -k --keepParent build/OpenWispr.app build/OpenWispr.zip
else
  echo "NOT NOTARIZED (self-signed)"
fi
./build_dmg.sh

# Sparkle feed (SUFeedURL) stays on openwispr.vercel.app. Update zips are versioned on the private host.
ZIP="OpenWispr-$VER.zip"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
cp build/OpenWispr.zip "$SCRATCH/$ZIP"; cp "$NOTES" "$SCRATCH/OpenWispr-$VER.md"
GEN=.build/artifacts/sparkle/Sparkle/bin/generate_appcast
"$GEN" --download-url-prefix "$DIST_URL/" --embed-release-notes "$SCRATCH"
# A dry run merges into a scratch copy so the real feed never holds an unreleased build.
FEED=web/appcast.xml
if [ "$DRY" = "--dry-run" ]; then FEED="$SCRATCH/feed.xml"; [ ! -f web/appcast.xml ] || cp web/appcast.xml "$FEED"; fi
python3 Tools/merge_appcast_item.py --existing "$FEED" --generated "$SCRATCH/appcast.xml" \
  --build "$BUILD" --url "$DIST_URL/$ZIP"

if [ "$DRY" = "--dry-run" ]; then echo "dry run done: zip, dmg, appcast item (nothing uploaded, committed or pushed)"; exit 0; fi

# Files go live on the private host first, then the release commit, the notes-only GitHub release, then the appcast.
mkdir -p "$DIST_DIR"
cp build/OpenWispr.zip "$DIST_DIR/$ZIP"; cp build/OpenWispr.dmg "$DIST_DIR/OpenWispr.dmg"
(cd "$DIST" && vercel --prod --yes --scope "$VERCEL_SCOPE" >/dev/null)
for f in "$ZIP" OpenWispr.dmg; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$DIST_URL/$f")" = 200 ] || { echo "ERROR: $f not on the private host; nothing published"; exit 1; }
done
git add -A && git reset -q build target .build .grind.log 2>/dev/null || true
git reset -q -- web/appcast.xml
git commit -m "chore: release $VER"
git push origin master
gh release create "v$VER" --title "OpenWispr $VER" --notes-file "$NOTES" --target "$(git rev-parse HEAD)"
git add web/appcast.xml && git commit -m "appcast: $VER"
git push origin master
# web/ deploys from the master push (the CLI is not linked to that project). Wait for the live feed.
for _ in $(seq 1 30); do
  curl -fs "https://openwispr.vercel.app/appcast.xml" | grep -q "<sparkle:version>$BUILD<" && { echo "appcast live: $VER"; exit 0; }
  sleep 10
done
echo "WARNING: openwispr.vercel.app/appcast.xml does not list $VER yet; check the Vercel deploy."
