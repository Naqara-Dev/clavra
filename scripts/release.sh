#!/bin/bash
# Builds a release of Clavra: dist/Clavra-X.dmg and dist/appcast.xml. Publish both on the same
# GitHub release; the app reads releases/latest/download/appcast.xml.
#
#   ./scripts/release.sh                 Signed with the "Naqara Dev Code Signing" certificate in your
#                                        keychain when it's there (ad-hoc otherwise). Gatekeeper still
#                                        warns on first install; updates after that install in place.
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="clavra-notary" ./scripts/release.sh
#                                        Signed, notarized and stapled, ready for anyone.
#
# One-time setup:
#   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account naqara-clavra
#     (the private key stays in your login keychain; its public half is SUPublicEDKey in Config/Info.plist)
#   xcrun notarytool store-credentials clavra-notary --apple-id you@example.com --team-id TEAMID
#     (only with a paid Apple Developer account)
#
# Bump CURRENT_PROJECT_VERSION every release: Sparkle compares that build number.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Clavra.xcodeproj/project.pbxproj | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' Clavra.xcodeproj/project.pbxproj | head -1)
OUT=${OUT:-dist}
SELF_SIGNED="Naqara Dev Code Signing"
ARCHIVE=build/Clavra.xcarchive
PACKAGES=build/SourcePackages
SPARKLE_BIN=$PACKAGES/artifacts/sparkle/Sparkle/bin
DMG="$OUT/Clavra-$VERSION.dmg"
FEED_BASE=${FEED_BASE:-https://github.com/Naqara-Dev/clavra/releases/download/v$VERSION}
rm -rf "$OUT" "$ARCHIVE" && mkdir -p "$OUT"

echo "› Testing"
./scripts/test.sh

echo "› Archiving Clavra $VERSION ($BUILD)"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  TEAM=$(echo "$DEVELOPER_ID" | sed -n 's/.*(\(.*\))/\1/p')
  xcodebuild archive -project Clavra.xcodeproj -scheme Clavra -configuration Release -archivePath "$ARCHIVE" \
    -clonedSourcePackagesDirPath "$PACKAGES" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet
else
  echo "  DEVELOPER_ID not set: building ad-hoc, then signing with \"$SELF_SIGNED\" if it's in the keychain."
  xcodebuild archive -project Clavra.xcodeproj -scheme Clavra -configuration Release -archivePath "$ARCHIVE" \
    -clonedSourcePackagesDirPath "$PACKAGES" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" -quiet
fi

APP="$ARCHIVE/Products/Applications/Clavra.app"
[[ -d "$APP" ]] || { echo "Archive has no app"; exit 1; }

# An ad-hoc signature changes with every build, so macOS would treat each update as a new app (and
# the Keychain would ask again for Clavra's saved passwords). A certificate that stays the same keeps
# them trusted.
if [[ -z "${DEVELOPER_ID:-}" ]] && security find-certificate -c "$SELF_SIGNED" >/dev/null 2>&1; then
  echo "› Signing with \"$SELF_SIGNED\""
  sign() { codesign --force --sign "$SELF_SIGNED" --timestamp=none --options runtime --preserve-metadata=identifier,entitlements "$1"; }
  # Nested code first (Sparkle's helpers, then its framework), the app last.
  find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.dylib" \
    -o \( -name Autoupdate -type f \) \) -print0 |
    while IFS= read -r -d '' code; do sign "$code"; done
  # Library validation only accepts frameworks from Apple or the app's own team, and a self-signed
  # certificate has no team, so Clavra couldn't load Sparkle. Developer ID builds keep it on.
  ENTITLEMENTS=$(mktemp)
  codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null
  [[ -s "$ENTITLEMENTS" ]] || printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
  codesign --force --sign "$SELF_SIGNED" --timestamp=none --options runtime --preserve-metadata=identifier \
    --entitlements "$ENTITLEMENTS" "$APP"
  rm -f "$ENTITLEMENTS"
  codesign --verify --strict "$APP"
fi

echo "› Creating $DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clavra" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "› Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "  NOTARY_PROFILE not set: signed but not notarized."
  fi
fi

# The feed Sparkle reads, signed with the EdDSA key in your keychain.
echo "› Writing appcast.xml"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account naqara-clavra "$DMG")
cat > "$OUT/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Clavra</title>
    <item>
      <title>Clavra $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <enclosure url="$FEED_BASE/Clavra-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
FEED

shasum -a 256 "$DMG"
echo "✓ $DMG"
echo "✓ $OUT/appcast.xml"
