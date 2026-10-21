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

# Architectures to build. A local build targets this Mac only: Command Line
# Tools ship the Swift compatibility libraries for the host architecture alone,
# so an x86_64 slice can't link on an Apple-silicon Mac without Xcode. The
# release workflow sets UNIVERSAL=1, and then both slices are required — a
# failed x86_64 slice fails the build rather than shipping an arm64-only
# release that Intel Macs would install and be unable to run.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

echo "=== Building ${APP_NAME} ==="

SOURCES=(PathResolver.swift UsageClient.swift UsageColors.swift StatusBarView.swift \
    UsagePanelView.swift Screenshot.swift Updater.swift AppDelegate.swift main.swift)
COMMON_FLAGS=(-Osize -wmo -module-name "${APP_NAME}" -Xlinker -dead_strip \
    -framework AppKit -framework Foundation -framework Security -framework ServiceManagement)

# Compile one slice per architecture, pinning the deployment target so the
# binary runs on macOS ${DEPLOYMENT_TARGET}+, then join them with lipo.
echo "[1/3] Compiling ${ARCHS[*]} binary, min macOS ${DEPLOYMENT_TARGET}..."
SLICES=()
trap 'rm -f "${SLICES[@]}"' EXIT   # don't leave a slice behind when a compile fails
for arch in "${ARCHS[@]}"; do
    SLICES+=("${APP_NAME}_${arch}")
    swiftc "${COMMON_FLAGS[@]}" -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        "${SOURCES[@]}" -o "${APP_NAME}_${arch}"
done
lipo -create "${SLICES[@]}" -output "${APP_NAME}_bin"
# One arch per call: given several, lipo reads the second as an input file.
for arch in "${ARCHS[@]}"; do
    lipo "${APP_NAME}_bin" -verify_arch "${arch}" \
        || { echo "Error: ${APP_NAME}_bin has no ${arch} slice"; exit 1; }
done

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
