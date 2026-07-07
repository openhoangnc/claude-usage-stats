#!/bin/bash
set -e

APP_NAME="ClaudeUsageStats"
APP_BUNDLE="${APP_NAME}.app"

echo "=== Building ${APP_NAME} ==="

echo "[1/3] Compiling Swift sources..."
swiftc -Osize -wmo \
    -module-name "${APP_NAME}" \
    -Xlinker -dead_strip \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework ServiceManagement \
    PathResolver.swift \
    UsageClient.swift \
    UsageColors.swift \
    StatusBarView.swift \
    UsagePanelView.swift \
    Screenshot.swift \
    AppDelegate.swift \
    main.swift \
    -o "${APP_NAME}_bin"

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
