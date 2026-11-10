#!/bin/sh
# Print the path of the openwispr CLI: installed app first, then a repo build.
for p in /Applications/OpenWispr.app/Contents/Helpers/openwispr \
         "$HOME/Applications/OpenWispr.app/Contents/Helpers/openwispr" \
         "$HOME/claude/whispr/build/OpenWispr.app/Contents/Helpers/openwispr"; do
    [ -x "$p" ] && { echo "$p"; exit 0; }
done
echo "openwispr CLI not found; install OpenWispr.app" >&2
exit 1
