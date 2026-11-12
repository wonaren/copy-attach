#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d /tmp/copyattach-update-notes-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -disable-sandbox \
    -module-cache-path /tmp/copyattach_module_cache \
    -framework AppKit \
    SwiftApp/Update/UpdateChecker.swift SwiftApp/Update/UpdateBadge.swift \
    SwiftApp/Update/UpdateDownloader.swift scripts/update_notes_test.swift \
    -o "$TEST_DIR/CopyAttachUpdateNotesCheck"
TMPDIR="$TEST_DIR" "$TEST_DIR/CopyAttachUpdateNotesCheck"
