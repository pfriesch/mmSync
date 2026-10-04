#!/bin/bash
# Builds build/mmSync-<version>.dmg: Release archive, signed with Developer ID,
# and notarized + stapled when NOTARY_PROFILE is set.
#
#   scripts/package.sh                                 # signed only
#   NOTARY_PROFILE=mmsync-notary scripts/package.sh    # signed + notarized
#
# One-time notary setup (asks for an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials mmsync-notary --apple-id <apple-id> --team-id D7J2ARX9TD
#
# Version: MARKETING_VERSION / CURRENT_PROJECT_VERSION in the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=D7J2ARX9TD
BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "→ Archiving"
xcodebuild archive -quiet \
    -project mmSync.xcodeproj -scheme mmSync -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$BUILD/mmSync.xcarchive"

echo "→ Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet \
    -archivePath "$BUILD/mmSync.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$BUILD/export"

APP="$BUILD/export/mmSync.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD/mmSync-$VERSION.dmg"

echo "→ Creating $DMG"
mkdir "$BUILD/dmg"
cp -R "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -quiet -volname mmSync -srcfolder "$BUILD/dmg" -format UDZO "$DMG"
codesign --sign "Developer ID Application: Pius Friesch ($TEAM)" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ Notarizing (takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG" # fails unless Apple accepted it
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "⚠ Not notarized: other Macs will refuse to open it. Set NOTARY_PROFILE to notarize." >&2
fi

echo "✓ $DMG"
