#!/bin/bash
# Build script for CopyAttach
set -e

cd "$(dirname "$0")"

export PATH="$HOME/.cargo/bin:$PATH"

APP_NAME="CopyAttach"
SWIFT_SRC="SwiftApp"

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

# License environment is selected at build time. The default is production
# with baked-in values; override any COPYATTACH_* variable to point elsewhere.
# Local development must pass the public key printed by license-server.
LICENSE_ENV="${LICENSE_ENV:-production}"
if [ "$LICENSE_ENV" = "local" ]; then
    LICENSE_SERVER_URL="http://127.0.0.1:8787"
    LICENSE_SIGNING_KEY_ID="${COPYATTACH_LICENSE_KEY_ID:-development-2026-01}"
    COPYATTACH_LICENSE_PUBLIC_KEY="${COPYATTACH_LICENSE_PUBLIC_KEY:?Set COPYATTACH_LICENSE_PUBLIC_KEY to the local dev server Ed25519 public key}"
else
    LICENSE_SERVER_URL="${COPYATTACH_LICENSE_SERVER_URL:-https://api.abovepast.shop}"
    LICENSE_SIGNING_KEY_ID="${COPYATTACH_LICENSE_KEY_ID:-production-2026-08}"
    COPYATTACH_LICENSE_PUBLIC_KEY="${COPYATTACH_LICENSE_PUBLIC_KEY:-efsKYx9a7urNlr-UXR7b0-Fl9w0mJNKe3RME-OeseOs}"
fi

# Compile with explicit args
$SWIFTC $SDK \
    -disable-sandbox \
    -module-cache-path /tmp/copyattach_module_cache \
    -Xcc -fmodules-cache-path=/tmp/copyattach_clang_cache \
    -target arm64-apple-macosx15.0 \
    -swift-version 6 \
    -O \
    -whole-module-optimization \
    -framework CryptoKit \
    -framework IOKit \
    -framework Security \
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

# Copy and configure Info.plist in app bundle.
# Keep the tracked source plist (${SWIFT_SRC}/Info.plist) completely clean and unmodified.
TARGET_PLIST="${APP_NAME}.app/Contents/Info.plist"
cp "${SWIFT_SRC}/Info.plist" "${TARGET_PLIST}"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${CARGO_VERSION}" "${TARGET_PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete CopyAttachLicenseServerURL" "${TARGET_PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add CopyAttachLicenseServerURL string ${LICENSE_SERVER_URL}" "${TARGET_PLIST}"
/usr/libexec/PlistBuddy -c "Delete CopyAttachLicenseSigningKeyID" "${TARGET_PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add CopyAttachLicenseSigningKeyID string ${LICENSE_SIGNING_KEY_ID}" "${TARGET_PLIST}"
/usr/libexec/PlistBuddy -c "Delete CopyAttachLicenseSigningPublicKey" "${TARGET_PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add CopyAttachLicenseSigningPublicKey string ${COPYATTACH_LICENSE_PUBLIC_KEY}" "${TARGET_PLIST}"
if [ "$LICENSE_ENV" = "local" ]; then
    /usr/libexec/PlistBuddy -c "Delete NSAppTransportSecurity" "${TARGET_PLIST}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add NSAppTransportSecurity dict" "${TARGET_PLIST}"
    /usr/libexec/PlistBuddy -c "Add NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "${TARGET_PLIST}"
else
    /usr/libexec/PlistBuddy -c "Delete NSAppTransportSecurity" "${TARGET_PLIST}" 2>/dev/null || true
fi

# Copy bridging header for reference
cp "${SWIFT_SRC}/CopyAttach-Bridging-Header.h" "${APP_NAME}.app/Contents/Resources/"

# Set rpath if not already set
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_NAME}.app/Contents/MacOS/CopyAttach" 2>/dev/null || true

echo "==> Signing app bundle…"
# 优先用已安装的正式签名身份（Apple Development / Developer ID）签名。
# 正式身份让钥匙串 ACL 按稳定标识匹配：ad-hoc 签名的 cdhash 每次构建都会变，
# 导致每次重新打开 App 都弹「CopyAttach想要使用钥匙串中的机密信息」。
# 用正式身份后重建/重装都不会再弹（首次启动对旧条目点一次「始终允许」即可）。
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1 || true)
if [ -n "$SIGN_IDENTITY" ]; then
    echo "  Using signing identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "${APP_NAME}.app" 2>&1
else
    echo "  No signing identity found, falling back to ad-hoc signature"
    codesign --force --deep --sign - "${APP_NAME}.app" 2>&1
fi

echo "==> Done! App bundle at '${APP_NAME}.app'"
echo "==> Run: open \"${APP_NAME}.app\""
