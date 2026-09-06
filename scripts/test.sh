#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/ClipboardKit
CLIPPY_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clippy-tests.XXXXXX")
trap 'rm -rf "$CLIPPY_TEST_DIR"' EXIT
swiftc -parse-as-library Clippy/Services/AIChatService.swift Clippy/Services/CodexConnection.swift tests/StreamingTests.swift -o "$CLIPPY_TEST_DIR/streaming-tests"
if [ -x .build/codex/universal/codex ]; then
  "$CLIPPY_TEST_DIR/streaming-tests" "$PWD/.build/codex/universal/codex"
else
  "$CLIPPY_TEST_DIR/streaming-tests"
fi

swiftc -parse-as-library Clippy/Services/HotkeyHandler.swift tests/HotkeyTests.swift -o "$CLIPPY_TEST_DIR/hotkey-tests"
"$CLIPPY_TEST_DIR/hotkey-tests"
