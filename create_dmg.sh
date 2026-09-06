#!/bin/bash
# Produce a Developer ID signed, notarized DMG. Never label an unsigned build publishable.
set -euo pipefail
cd "$(dirname "$0")"
: "${CLIPPY_SIGNING_IDENTITY:?Set CLIPPY_SIGNING_IDENTITY to your Developer ID Application certificate name}"
: "${CLIPPY_NOTARY_PROFILE:?Set CLIPPY_NOTARY_PROFILE to an existing notarytool Keychain profile}"
if [[ "$CLIPPY_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "A Developer ID Application identity is required for public downloads." >&2
    exit 1
fi
# Preflight signing before spending time on a release build.
security find-identity -v -p codesigning | /usr/bin/grep -Fq "$CLIPPY_SIGNING_IDENTITY" || {
    echo "The requested signing identity and private key are not available." >&2; exit 1;
}
xcrun notarytool history --keychain-profile "$CLIPPY_NOTARY_PROFILE" >/dev/null
python3 scripts/fetch-codex.py
CLIPPY_RELEASE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/clippy-release.XXXXXX")
trap 'rm -rf "$CLIPPY_RELEASE_WORK"' EXIT
xcodebuild -project Clippy.xcodeproj -scheme Clippy -configuration Release \
    -derivedDataPath build-release -destination 'generic/platform=macOS' \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CLIPPY_SIGNING_IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp \
    ENABLE_HARDENED_RUNTIME=YES build
CLIPPY_APP="$PWD/build-release/Build/Products/Release/Clippy.app"
codesign --verify --deep --strict --verbose=2 "$CLIPPY_APP"
CLIPPY_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CLIPPY_APP/Contents/Info.plist")
CLIPPY_FEED_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$CLIPPY_APP/Contents/Info.plist")
CLIPPY_SPARKLE_BIN="$PWD/build-release/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Confirm the existing signing key matches the public key trusted by installed apps.
# Never generate a replacement key implicitly: existing installs trust the old one.
CLIPPY_EXISTING_KEY=$("$CLIPPY_SPARKLE_BIN/generate_keys" -p)
if [[ "$CLIPPY_EXISTING_KEY" != "$CLIPPY_FEED_KEY" ]]; then
    echo "Existing Sparkle signing key does not match the app's public key." >&2; exit 1
fi
mkdir -p release "$CLIPPY_RELEASE_WORK/image"
ditto -c -k --keepParent "$CLIPPY_APP" "$CLIPPY_RELEASE_WORK/Clippy.zip"
xcrun notarytool submit "$CLIPPY_RELEASE_WORK/Clippy.zip" --keychain-profile "$CLIPPY_NOTARY_PROFILE" --wait
xcrun stapler staple "$CLIPPY_APP"
xcrun stapler validate "$CLIPPY_APP"
spctl --assess --type execute --verbose=2 "$CLIPPY_APP"
ditto "$CLIPPY_APP" "$CLIPPY_RELEASE_WORK/image/Clippy.app"
ln -s /Applications "$CLIPPY_RELEASE_WORK/image/Applications"
CLIPPY_DMG="$CLIPPY_RELEASE_WORK/Clippy-$CLIPPY_VERSION.dmg"
hdiutil create -volname Clippy -srcfolder "$CLIPPY_RELEASE_WORK/image" -format UDZO "$CLIPPY_DMG"
codesign --force --sign "$CLIPPY_SIGNING_IDENTITY" --timestamp "$CLIPPY_DMG"
xcrun notarytool submit "$CLIPPY_DMG" --keychain-profile "$CLIPPY_NOTARY_PROFILE" --wait
xcrun stapler staple "$CLIPPY_DMG"
xcrun stapler validate "$CLIPPY_DMG"
"$CLIPPY_SPARKLE_BIN/sign_update" "$CLIPPY_DMG" > "$CLIPPY_RELEASE_WORK/signature.txt"
CLIPPY_SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$CLIPPY_RELEASE_WORK/signature.txt")
test -n "$CLIPPY_SIGNATURE"
"$CLIPPY_SPARKLE_BIN/sign_update" --verify "$CLIPPY_DMG" "$CLIPPY_SIGNATURE"
# Export only after every validation succeeds.
ditto "$CLIPPY_DMG" "release/Clippy-$CLIPPY_VERSION.dmg"
cp "$CLIPPY_RELEASE_WORK/signature.txt" "release/Clippy-$CLIPPY_VERSION.signature.txt"
shasum -a 256 "release/Clippy-$CLIPPY_VERSION.dmg" > "release/Clippy-$CLIPPY_VERSION.sha256"
echo "Verified release: release/Clippy-$CLIPPY_VERSION.dmg"
echo "Publish this DMG before adding its signed enclosure to the HTTPS appcast."
