#!/bin/zsh
# Build, sign, notarize and package Station into ./dist:
#   dist/Station.zip           the notarized, stapled app (the in-app updater installs this one)
#   dist/Station-<version>.dmg for people installing by hand
# Usage: scripts/release.sh [--notarize-dmg]
# The app inside the DMG is what Gatekeeper checks, so the DMG itself is only signed unless
# --notarize-dmg (that second wait is where Apple's service tends to stall).
# One-time setup: a "Developer ID Application" certificate in the keychain, and
#   xcrun notarytool store-credentials station --apple-id <apple id> --team-id S3RY6Q3EW2
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')
TEAM=$(grep DEVELOPMENT_TEAM project.yml | head -1 | awk '{print $2}')
NOTARIZE_DMG=0; [ "${1:-}" = "--notarize-dmg" ] && NOTARIZE_DMG=1
DIST=dist; rm -rf "$DIST"; mkdir -p "$DIST"
say() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }

say "Rust core (universal)"
scripts/build-core.sh
xcodegen generate >/dev/null

# Never ship slower: scripts/perf.sh holds the budgets. SKIP_PERF=1 only for an emergency fix.
if [ "${SKIP_PERF:-}" != 1 ]; then say "Perf budget"; scripts/perf.sh; fi

say "Archiving Station $VERSION"
xcodebuild archive -scheme Station -configuration Release -archivePath "$DIST/Station.xcarchive" \
  -derivedDataPath "$DIST/dd" -destination 'generic/platform=macOS' -allowProvisioningUpdates -quiet

say "Exporting with Developer ID"
cat > "$DIST/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$DIST/Station.xcarchive" -exportOptionsPlist "$DIST/export.plist" \
  -exportPath "$DIST/export" -allowProvisioningUpdates -quiet
APP="$DIST/Station.app"
cp -R "$DIST/export/Station.app" "$APP"

say "Notarizing the app (usually 1–5 minutes)"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile station --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -v "$APP"
rm -f "$DIST/notarize.zip"

say "Packaging"
ditto -c -k --keepParent "$APP" "$DIST/Station.zip"
rm -rf "$DIST/dmgroot"; mkdir "$DIST/dmgroot"; cp -R "$APP" "$DIST/dmgroot/"; ln -s /Applications "$DIST/dmgroot/Applications"
hdiutil create -quiet -volname Station -srcfolder "$DIST/dmgroot" -ov -format UDZO "$DIST/Station-$VERSION.dmg"
codesign --force --sign "Developer ID Application" --timestamp "$DIST/Station-$VERSION.dmg"
if [ "$NOTARIZE_DMG" = 1 ]; then
  say "Notarizing the DMG"
  xcrun notarytool submit "$DIST/Station-$VERSION.dmg" --keychain-profile station --wait
  xcrun stapler staple "$DIST/Station-$VERSION.dmg"
fi
rm -rf "$DIST/dmgroot"
say "Built $DIST/Station.zip and $DIST/Station-$VERSION.dmg"
echo "publish: gh release create v$VERSION $DIST/Station-$VERSION.dmg $DIST/Station.zip --title 'Station $VERSION' --notes-file NOTES.md"
