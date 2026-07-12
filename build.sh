#!/bin/bash
set -e

APP_NAME="ClaudeUsageStats"
APP_BUNDLE="${APP_NAME}.app"

# Minimum macOS version. MUST match LSMinimumSystemVersion in Info.plist.
# This gets baked into the binary's LC_BUILD_VERSION (minos), which is what
# Launch Services actually checks. Without an explicit -target, swiftc stamps
# minos to the *build machine's* OS version, so the app fails to launch on any
# older Mac with error -10825 (kLSIncompatibleSystemVersionErr).
DEPLOYMENT_TARGET="11.0"

echo "=== Building ${APP_NAME} ==="

SOURCES=(PathResolver.swift UsageClient.swift UsageColors.swift StatusBarView.swift \
    UsagePanelView.swift Screenshot.swift AppDelegate.swift main.swift)
COMMON_FLAGS=(-Osize -wmo -module-name "${APP_NAME}" -Xlinker -dead_strip \
    -framework AppKit -framework Foundation -framework Security -framework ServiceManagement)

# Compile a universal (arm64 + x86_64) binary, pinning the deployment target so
# it runs on macOS ${DEPLOYMENT_TARGET}+ on both Apple Silicon and Intel Macs.
echo "[1/3] Compiling universal binary (arm64 + x86_64), min macOS ${DEPLOYMENT_TARGET}..."
swiftc "${COMMON_FLAGS[@]}" -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
    "${SOURCES[@]}" -o "${APP_NAME}_arm64"
swiftc "${COMMON_FLAGS[@]}" -target "x86_64-apple-macosx${DEPLOYMENT_TARGET}" \
    "${SOURCES[@]}" -o "${APP_NAME}_x86_64"
lipo -create "${APP_NAME}_arm64" "${APP_NAME}_x86_64" -output "${APP_NAME}_bin"
rm -f "${APP_NAME}_arm64" "${APP_NAME}_x86_64"

strip -x "${APP_NAME}_bin" || true

echo "[2/3] Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mv "${APP_NAME}_bin" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_BUNDLE}/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "${APP_BUNDLE}/Contents/Resources/" || true

echo "[3/3] Signing locally (ad-hoc)..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "=== Build complete: $(pwd)/${APP_BUNDLE} ==="
echo "Run with: open ${APP_BUNDLE}"
