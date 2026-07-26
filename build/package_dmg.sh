#!/bin/bash
# Package CopyAttach.app into a DMG for distribution
set -e

cd "$(dirname "$0")/.."

APP_NAME="CopyAttach"
APP_PATH="${1:-${APP_NAME}.app}"
OUTPUT_DIR="${2:-build}"

# Read version from Cargo.toml
VERSION=$(grep '^version = ' Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

# Ensure the .app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run ./build.sh first."
    exit 1
fi

echo "==> Packaging ${APP_NAME} v${VERSION} → ${DMG_PATH}"

# Create temp directory for DMG contents
DMG_TMP=$(mktemp -d -t "${APP_NAME}-dmg")
trap 'rm -rf "${DMG_TMP}"' EXIT

STAGING_DIR="${DMG_TMP}/staging"
mkdir -p "${STAGING_DIR}"

# Copy .app into staging
echo "==> Copying ${APP_NAME}.app…"
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"

# Create /Applications symlink for drag-and-drop install
ln -s /Applications "${STAGING_DIR}/Applications"

# Create a read-write DMG from staging (needed so we can set the volume icon)
echo "==> Creating read-write DMG…"
mkdir -p "${OUTPUT_DIR}"

RW_DMG="${DMG_TMP}/CopyAttach-rw.dmg"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${RW_DMG}"

# Set custom volume icon on the mounted read-write image
# Uses icon_inner.svg which has a white rounded-background,
# unlike icon.svg (transparent, used for the app icon).
if [ -f "assets/icon_inner.svg" ]; then
    echo "==> Generating DMG volume icon from assets/icon_inner.svg…"
    VOLUME_ICONSET="${DMG_TMP}/volume-icon.iconset"
    VOLUME_ICNS="${DMG_TMP}/VolumeIcon.icns"
    mkdir -p "${VOLUME_ICONSET}"

    sips -s format png "assets/icon_inner.svg" --out "${VOLUME_ICONSET}/base.png" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size "${VOLUME_ICONSET}/base.png" --out "${VOLUME_ICONSET}/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "${VOLUME_ICONSET}/base.png" --out "${VOLUME_ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "${VOLUME_ICONSET}" -o "${VOLUME_ICNS}"

    echo "==> Setting custom volume icon…"
    TEMP_MOUNT="/tmp/${APP_NAME}-volume"
    rm -rf "${TEMP_MOUNT}"
    mkdir -p "${TEMP_MOUNT}"

    # Mount with -readwrite so SetFile can write HFS+ attributes
    RW_DEV=$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse \
        -mountpoint "${TEMP_MOUNT}" "${RW_DMG}" 2>/dev/null \
        | grep '/dev/disk' | grep -v 'GUID_partition' | tail -1 | awk '{print $1}')

    cp "${VOLUME_ICNS}" "${TEMP_MOUNT}/.VolumeIcon.icns"

    # Set file type to icon container (icnC) — tells macOS this is a volume icon file
    SetFile -c icnC "${TEMP_MOUNT}/.VolumeIcon.icns"
    # Set "has custom icon" HFS+ attribute on the volume root
    SetFile -a C "${TEMP_MOUNT}"

    echo "  Volume icon set (SetFile -c icnC + SetFile -a C)"

    hdiutil detach "${RW_DEV}" > /dev/null
fi

# Convert the read-write DMG to compressed read-only UDZO
echo "==> Compressing DMG…"
hdiutil convert "${RW_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}"

echo "==> Done! DMG at: ${DMG_PATH}"
echo "==> open \"${DMG_PATH}\""
