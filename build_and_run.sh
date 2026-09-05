#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# A failed build must never remove or replace an installed copy.
xcodebuild -project Clippy.xcodeproj -scheme Clippy -configuration Debug \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/Clippy.app
