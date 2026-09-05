#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CLIPPY_APPLE_TEAM:?Set the verified Univation signing Team ID}"
: "${CLIPPY_APP_GROUP:?Set the registered, provisioned App Group identifier}"
: "${CLIPPY_STORE_PROFILE:?Set the Mac App Store provisioning profile name}"
xcodebuild -project Clippy.xcodeproj -scheme ClippyStore -configuration Release \
  -derivedDataPath build-store -destination 'generic/platform=macOS' -archivePath release/ClippyStore.xcarchive \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$CLIPPY_APPLE_TEAM" CLIPPY_APP_GROUP="$CLIPPY_APP_GROUP" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$CLIPPY_STORE_PROFILE" archive
CLIPPY_STORE_APP="$PWD/release/ClippyStore.xcarchive/Products/Applications/Clippy.app"
codesign --verify --deep --strict "$CLIPPY_STORE_APP"
if find "$CLIPPY_STORE_APP" -name 'Sparkle.framework' -print -quit | /usr/bin/grep -q .; then
  echo 'Store archive unexpectedly contains Sparkle.' >&2
  exit 1
fi
echo 'Archive created. Export for App Store Connect, upload, and wait for Apple processing.'
