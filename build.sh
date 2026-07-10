#!/bin/bash
# Build script for CopyAttach
set -e

cd "$(dirname "$0")"

APP_NAME="CopyAttach"
SWIFT_SRC="SwiftApp"

echo "==> Building Rust backend library…"
cargo build --release

echo "==> Building Swift frontend app…"

# Create app bundle structure
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Frameworks"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# Copy the Rust dylib into Frameworks and set its install name
cp "target/release/libcopy_attach.dylib" "${APP_NAME}.app/Contents/Frameworks/"
install_name_tool -id "@rpath/libcopy_attach.dylib" "${APP_NAME}.app/Contents/Frameworks/libcopy_attach.dylib"

# Find the Swift compiler and SDK
XCODE_TOOLCHAIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if [ -f "$XCODE_TOOLCHAIN/usr/bin/swiftc" ] && [ -d "$XCODE_SDK" ]; then
    SWIFTC="$XCODE_TOOLCHAIN/usr/bin/swiftc"
    SDK="-sdk $XCODE_SDK"
    echo "  Using Xcode toolchain: $XCODE_TOOLCHAIN"
else
    echo "  Xcode not found, using xcrun"
    SWIFTC="xcrun swiftc"
    SDK=""
fi

echo "==> Compiling Swift sources…"

# Compile with explicit args
"$SWIFTC" $SDK \
    -target arm64-apple-macosx15.0 \
    -o "${APP_NAME}.app/Contents/MacOS/CopyAttach" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -L "${APP_NAME}.app/Contents/Frameworks" \
    -lcopy_attach \
    -I "${SWIFT_SRC}" \
    -import-objc-header "${SWIFT_SRC}/CopyAttach-Bridging-Header.h" \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -Xlinker -rpath -Xlinker "/usr/local/lib" \
    "${SWIFT_SRC}/CopyAttachApp.swift" \
    "${SWIFT_SRC}/ClipboardBackend.swift" \
    "${SWIFT_SRC}/HistoryPopupView.swift" \
    "${SWIFT_SRC}/HotkeyManager.swift"

# Copy Info.plist
cp "${SWIFT_SRC}/Info.plist" "${APP_NAME}.app/Contents/"

# Copy bridging header for reference
cp "${SWIFT_SRC}/CopyAttach-Bridging-Header.h" "${APP_NAME}.app/Contents/Resources/"

# Set rpath if not already set
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_NAME}.app/Contents/MacOS/CopyAttach" 2>/dev/null || true

echo "==> Signing app bundle…"
codesign --force --deep --sign - "${APP_NAME}.app" 2>&1

echo "==> Done! App bundle at '${APP_NAME}.app'"
echo "==> Run: open \"${APP_NAME}.app\""
