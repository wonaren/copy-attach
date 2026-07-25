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

# Create the DMG
echo "==> Creating DMG…"
mkdir -p "${OUTPUT_DIR}"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "${DMG_PATH}"

echo "==> Done! DMG at: ${DMG_PATH}"
echo "==> open \"${DMG_PATH}\""
