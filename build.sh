#!/bin/bash
# Build script for CopyAttach
set -e

cd "$(dirname "$0")"

export PATH="$HOME/.cargo/bin:$PATH"

APP_NAME="CopyAttach"
SWIFT_SRC="SwiftApp"
APP_OUTPUT="${APP_NAME}.app"

SIGN_LIST=$(security find-identity -v -p codesigning)
SIGN_IDENTITY=$(printf '%s\n' "$SIGN_LIST" \
    | awk '/^[[:space:]]*[0-9]+\)/ && /Developer ID Application|Apple Development/ {print $2; exit}')

check_output_signature() {
    if [ -z "$SIGN_IDENTITY" ] && { [ -e "$APP_OUTPUT" ] || [ -L "$APP_OUTPUT" ]; }; then
        if ! codesign -dv --verbose=4 "$APP_OUTPUT" 2>&1 | grep -qx 'Signature=adhoc'; then
            echo "error: no Apple Development or Developer ID Application signing identity is available. Existing ${APP_OUTPUT} was preserved." >&2
            exit 1
        fi
    fi
}

check_output_signature

BUILD_DIR=$(mktemp -d "$PWD/.copyattach-build.XXXXXX")
APP_BUNDLE="$BUILD_DIR/$APP_OUTPUT"
PUBLISH_LOCK=""
cleanup() {
    rm -rf "$BUILD_DIR"
    if [ -n "$PUBLISH_LOCK" ]; then
        rmdir "$PUBLISH_LOCK"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "==> Building Rust backend library…"

# Read version from Cargo.toml
CARGO_VERSION=$(grep '^version = ' Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')

# Build with optional stress-test feature (set STRESS=1 to enable)
CARGO_FEATURES=""
if [ "${STRESS}" = "1" ]; then
    echo "==> Including stress-test feature…"
    CARGO_FEATURES="--features stress-test"
fi
cargo build --release ${CARGO_FEATURES}

echo "==> Building Swift frontend app…"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks" "$APP_BUNDLE/Contents/Resources"

# Generate AppIcon.icns from SVG if assets/icon.svg exists
if [ -f "assets/icon.svg" ]; then
    echo "==> Generating AppIcon.icns from assets/icon.svg..."
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir "$ICONSET"
    # sips handles SVG rendering correctly (unlike NSImage-based Swift renderer)
    sips -s format png assets/icon.svg --out "$ICONSET/base.png" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
elif [ -f "assets/AppIcon.icns" ]; then
    cp "assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copy SVG resources
cp "assets/about/github.svg" "assets/about/menubar-stack.svg" "assets/icon.svg" "assets/icon_inner.svg" "$APP_BUNDLE/Contents/Resources/"

# Copy the Rust dylib into Frameworks and set its install name
cp "target/release/libcopy_attach.dylib" "$APP_BUNDLE/Contents/Frameworks/"
install_name_tool -id "@rpath/libcopy_attach.dylib" "$APP_BUNDLE/Contents/Frameworks/libcopy_attach.dylib"

# Find the Swift compiler and SDK
XCODE_TOOLCHAIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if command -v xcrun >/dev/null 2>&1; then
    SWIFTC="xcrun swiftc"
    SDK="-sdk $(xcrun --show-sdk-path)"
    echo "  Using xcrun swiftc with SDK: $(xcrun --show-sdk-path)"
elif [ -f "$XCODE_TOOLCHAIN/usr/bin/swiftc" ] && [ -d "$XCODE_SDK" ]; then
    SWIFTC="$XCODE_TOOLCHAIN/usr/bin/swiftc"
    SDK="-sdk $XCODE_SDK"
    echo "  Using Xcode toolchain: $XCODE_TOOLCHAIN"
else
    echo "  Xcode not found, using swiftc directly"
    SWIFTC="swiftc"
    SDK=""
fi

echo "==> Compiling Swift sources…"

# Compile with explicit args
$SWIFTC $SDK \
    -disable-sandbox \
    -module-cache-path /tmp/copyattach_module_cache \
    -Xcc -fmodules-cache-path=/tmp/copyattach_clang_cache \
    -target arm64-apple-macosx15.0 \
    -swift-version 6 \
    -O \
    -whole-module-optimization \
    -o "$APP_BUNDLE/Contents/MacOS/CopyAttach" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -L "$APP_BUNDLE/Contents/Frameworks" \
    -lcopy_attach \
    -I "${SWIFT_SRC}" \
    -import-objc-header "${SWIFT_SRC}/CopyAttach-Bridging-Header.h" \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -Xlinker -rpath -Xlinker "/usr/local/lib" \
    $(find "${SWIFT_SRC}" -name '*.swift' | sort)

# Copy and configure Info.plist in app bundle.
# Keep the tracked source plist (${SWIFT_SRC}/Info.plist) completely clean and unmodified.
TARGET_PLIST="$APP_BUNDLE/Contents/Info.plist"
cp "${SWIFT_SRC}/Info.plist" "${TARGET_PLIST}"
# Critical plist writes must fail the build; only deleting an optional old key is allowed to be idempotent.
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${CARGO_VERSION}" "${TARGET_PLIST}"

# Copy bridging header for reference
cp "${SWIFT_SRC}/CopyAttach-Bridging-Header.h" "$APP_BUNDLE/Contents/Resources/"

# This is a required runtime search path for the bundled dylib.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/CopyAttach" 2>/dev/null || {
    # The path may already exist; verify that it is present instead of hiding
    # an unrelated install_name_tool failure.
    otool -l "$APP_BUNDLE/Contents/MacOS/CopyAttach" | grep -Fq '@executable_path/../Frameworks' || {
        echo "error: required Frameworks rpath is missing" >&2
        exit 1
    }
}

echo "==> Signing app bundle…"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "  Using signing identity: $SIGN_IDENTITY"
else
    echo "  No signing identity available. Using ad-hoc signature."
fi
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -E '^(Authority|Signature)=' | sed 's/^/  /' || true

cat > "$BUILD_DIR/Publish.swift" <<'EOF'
import Darwin

let candidate = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
if renamex_np(candidate, destination, UInt32(RENAME_EXCL)) != 0 {
    if errno != EEXIST || renamex_np(candidate, destination, UInt32(RENAME_SWAP)) != 0 {
        perror("Publishing CopyAttach.app")
        exit(1)
    }
}
EOF
$SWIFTC $SDK -module-cache-path /tmp/copyattach_module_cache "$BUILD_DIR/Publish.swift" -o "$BUILD_DIR/publish"

if ! mkdir .copyattach-publish.lock; then
    echo "error: another build is publishing ${APP_OUTPUT}" >&2
    exit 1
fi
PUBLISH_LOCK=.copyattach-publish.lock
check_output_signature
"$BUILD_DIR/publish" "$APP_BUNDLE" "$APP_OUTPUT"

echo "==> Done! App bundle at '${APP_NAME}.app'"
echo "==> Run: open \"${APP_NAME}.app\""
