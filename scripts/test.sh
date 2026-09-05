#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/ClipboardKit
CLIPPY_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clippy-tests.XXXXXX")
trap 'rm -rf "$CLIPPY_TEST_DIR"' EXIT
swiftc Clippy/Services/AIChatService.swift tests/StreamingTests.swift -o "$CLIPPY_TEST_DIR/streaming-tests"
"$CLIPPY_TEST_DIR/streaming-tests"
