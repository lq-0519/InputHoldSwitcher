#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/work/build"
OUTPUT_DIR="${PROJECT_DIR}/outputs"
APP_NAME="按住切换输入法.app"
APP_DIR="${BUILD_DIR}/${APP_NAME}"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"
export SWIFT_MODULECACHE_PATH="${BUILD_DIR}/SwiftModuleCache"

mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${OUTPUT_DIR}"

swiftc \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  "${PROJECT_DIR}/Sources/InputHoldSwitcher/main.swift" \
  -o "${APP_DIR}/Contents/MacOS/InputHoldSwitcher"

cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
DEFAULT_CODESIGN_IDENTITY="InputHoldSwitcher Local Code Signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SELECTED_CODESIGN_IDENTITY="${CODESIGN_IDENTITY}"
elif security find-identity -v -p codesigning | grep -q "${DEFAULT_CODESIGN_IDENTITY}"; then
  SELECTED_CODESIGN_IDENTITY="${DEFAULT_CODESIGN_IDENTITY}"
else
  SELECTED_CODESIGN_IDENTITY="-"
fi
codesign --force --deep --sign "${SELECTED_CODESIGN_IDENTITY}" "${APP_DIR}"
echo "Signed with: ${SELECTED_CODESIGN_IDENTITY}"

rm -rf "${OUTPUT_DIR}/${APP_NAME}"
ditto "${APP_DIR}" "${OUTPUT_DIR}/${APP_NAME}"
xattr -dr com.apple.quarantine "${OUTPUT_DIR}/${APP_NAME}" 2>/dev/null || true
xattr -dr com.apple.provenance "${OUTPUT_DIR}/${APP_NAME}" 2>/dev/null || true
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${OUTPUT_DIR}/InputHoldSwitcher-macOS.zip"

echo "Built: ${OUTPUT_DIR}/${APP_NAME}"
echo "Archive: ${OUTPUT_DIR}/InputHoldSwitcher-macOS.zip"
