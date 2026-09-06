#!/bin/sh
set -eu
runtime_arch="$CLIPPY_CODEX_ARCH"
runtime="$SRCROOT/.build/codex/$runtime_arch/codex"
if [ ! -x "$runtime" ]; then
  echo "error: Prepare the ChatGPT component with python3 scripts/fetch-codex.py --arch $runtime_arch"
  exit 1
fi
/usr/bin/lipo "$runtime" -verify_arch $ARCHS
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$destination"
cp -c "$runtime" "$destination/codex"
# Xcode deliberately skips signing in unsigned developer builds.
if [ "$(printenv CODE_SIGNING_ALLOWED || true)" = "NO" ]; then exit 0; fi
identity="$(printenv EXPANDED_CODE_SIGN_IDENTITY || true)"
if [ -z "$identity" ]; then identity="-"; fi
if [ "$TARGET_NAME" = "ClippyStore" ]; then
  /usr/bin/codesign --force --sign "$identity" --options runtime --entitlements "$SRCROOT/Clippy/CodexHelper.entitlements" "$destination/codex"
else
  /usr/bin/codesign --force --sign "$identity" --options runtime "$destination/codex"
fi
