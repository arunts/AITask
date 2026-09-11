#!/bin/zsh
# Builds, signs (Developer ID), notarizes and packages AITaskRunner for direct distribution.
#
# One-time setup — store notarization credentials in the keychain (needs an app-specific
# password from https://account.apple.com):
#   xcrun notarytool store-credentials AITaskRunner --apple-id <your Apple ID> --team-id <your Team ID> --password <app-specific password>
#
# Signing: put your Team ID in Config/Local.xcconfig (see Config/Local.xcconfig.example).
#
# Then: scripts/release.sh
# Output: build/release/AITaskRunner-<version>.dmg and .zip, both notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-AITaskRunner}"
OUT="build/release"
ARCHIVE="$OUT/AITaskRunner.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/AITaskRunner.app"

notarize() {
    local log
    log=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || { echo "$log"; exit 1; }
    echo "$log" | grep -E "^\s*(id|status):" | tail -n 2
    if ! echo "$log" | grep -q "status: Accepted"; then
        local id; id=$(echo "$log" | grep -m1 "id:" | awk '{print $2}')
        echo "Notarization failed. Details:"; xcrun notarytool log "$id" --keychain-profile "$PROFILE"
        exit 1
    fi
}

rm -rf "$OUT"; mkdir -p "$OUT"

echo "▸ Archiving (Release)"
xcodebuild -project AITaskRunner.xcodeproj -scheme AITaskRunner -configuration Release \
    -archivePath "$ARCHIVE" archive -quiet

echo "▸ Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ZIP="$OUT/AITaskRunner-$VERSION.zip"
DMG="$OUT/AITaskRunner-$VERSION.dmg"
echo "  AITaskRunner $VERSION ($BUILD)"

echo "▸ Notarizing app"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple -q "$APP"
rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the zip carries the stapled app

echo "▸ Building and notarizing disk image"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname AITaskRunner -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"   # Gatekeeper wants the container signed too
notarize "$DMG"
xcrun stapler staple -q "$DMG"

echo "▸ Gatekeeper check"
spctl -a -vv -t exec "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"

echo
echo "Done:"; ls -lh "$DMG" "$ZIP" | awk '{print "  " $5 "  " $9}'
echo
echo "To publish on the site:"
echo "  cp $DMG site/downloads/AITaskRunner.dmg && python3 site/build.py"
