#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d /tmp/copyattach-preview-session-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -O -parse-as-library \
    -module-cache-path /tmp/copyattach_module_cache \
    -framework AppKit \
    SwiftApp/Backend/ImageDecode.swift SwiftApp/Backend/PreviewDecodeGate.swift \
    scripts/preview_session_test.swift -o "$TEST_DIR/check"
"$TEST_DIR/check"
