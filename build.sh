#!/bin/bash
# Build script for CopyAttach
set -e

cd "$(dirname "$0")"

APP_NAME="CopyAttach"
SWIFT_SRC="SwiftApp"

echo "==> Building Rust backend library…"

# Read version from Cargo.toml and sync to Info.plist
CARGO_VERSION=$(grep '^version = ' Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${CARGO_VERSION}" "${SWIFT_SRC}/Info.plist" 2>/dev/null || true
cargo build --release

echo "==> Building Swift frontend app…"

# Create app bundle structure
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Frameworks"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# Generate AppIcon.icns from SVG if assets/icon.svg exists
if [ -f "assets/icon.svg" ]; then
    echo "==> Generating AppIcon.icns from assets/icon.svg..."
    mkdir -p AppIcon.iconset
    # sips handles SVG rendering correctly (unlike NSImage-based Swift renderer)
    sips -s format png assets/icon.svg --out AppIcon.iconset/base.png >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size AppIcon.iconset/base.png --out AppIcon.iconset/icon_${size}x${size}.png >/dev/null
        double=$((size * 2))
        sips -z $double $double AppIcon.iconset/base.png --out AppIcon.iconset/icon_${size}x${size}@2x.png >/dev/null
    done
    iconutil -c icns AppIcon.iconset -o assets/AppIcon.icns
    rm -rf AppIcon.iconset
fi

# Copy AppIcon.icns to resources if it exists
if [ -f "assets/AppIcon.icns" ]; then
    cp "assets/AppIcon.icns" "${APP_NAME}.app/Contents/Resources/AppIcon.icns"
fi

# Copy SVG resources
cp "assets/about/github.svg" "${APP_NAME}.app/Contents/Resources/github.svg"
cp "assets/about/menubar-stack.svg" "${APP_NAME}.app/Contents/Resources/menubar-stack.svg"
cp "assets/icon.svg" "${APP_NAME}.app/Contents/Resources/icon.svg"
cp "assets/icon_inner.svg" "${APP_NAME}.app/Contents/Resources/icon_inner.svg"

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
    $(find "${SWIFT_SRC}" -name '*.swift' | sort)

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
