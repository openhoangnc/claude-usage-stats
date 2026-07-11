#!/bin/bash
set -e

REPO="openhoangnc/claude-usage-stats"
APP_NAME="ClaudeUsageStats"
ZIP_NAME="${APP_NAME}.zip"
INSTALL_DIR="/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: ${APP_NAME} is only supported on macOS."
    exit 1
fi

echo "=== Installing ${APP_NAME} ==="

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Compile the Swift sources in $1, producing $1/<app>.app.
build_app() {
    local src_dir="$1"
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "Error: swiftc not found. Install Xcode command-line tools: xcode-select --install"
        exit 1
    fi
    ( cd "${src_dir}" \
        && { [ -f AppIcon.icns ] || ./make_icon.sh >/dev/null; } \
        && ./build.sh >/dev/null )
}

# Are we running from a local checkout? The script then sits next to the Swift
# sources. A piped run (curl | bash) has no on-disk script, so SRC_DIR stays empty.
SCRIPT_SRC="${BASH_SOURCE[0]:-$0}"
SRC_DIR=""
if [ -f "$SCRIPT_SRC" ]; then
    CANDIDATE="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
    if [ -f "${CANDIDATE}/build.sh" ] && [ -f "${CANDIDATE}/main.swift" ]; then
        SRC_DIR="$CANDIDATE"
    fi
fi

if [ -n "$SRC_DIR" ]; then
    # Local checkout: build and install YOUR current sources, not the release.
    echo "[1/4] Building from local source..."
    echo "--> ${SRC_DIR}"
    build_app "${SRC_DIR}"
    cp -R "${SRC_DIR}/${APP_NAME}.app" "${TMP_DIR}/"
else
    # Remote: download the latest published release, else clone and build.
    echo "[1/4] Downloading latest release..."
    LATEST_ZIP_URL="https://github.com/${REPO}/releases/latest/download/${ZIP_NAME}"
    if curl -fsSL -o "${TMP_DIR}/${ZIP_NAME}" "${LATEST_ZIP_URL}"; then
        echo "--> Downloaded ${ZIP_NAME} from GitHub Release."
        unzip -q "${TMP_DIR}/${ZIP_NAME}" -d "${TMP_DIR}"
    else
        echo "--> No prebuilt release available; building from source."
        git clone --depth 1 "https://github.com/${REPO}.git" "${TMP_DIR}/src"
        build_app "${TMP_DIR}/src"
        cp -R "${TMP_DIR}/src/${APP_NAME}.app" "${TMP_DIR}/"
    fi
fi

if [ ! -d "${TMP_DIR}/${APP_NAME}.app" ]; then
    echo "Error: Could not obtain ${APP_NAME}.app."
    exit 1
fi

echo "[2/4] Stopping any running instance..."
if pgrep -x "${APP_NAME}" >/dev/null; then
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
fi

echo "[3/4] Installing to ${APP_PATH}..."
rm -rf "${APP_PATH}"
cp -R "${TMP_DIR}/${APP_NAME}.app" "${INSTALL_DIR}/"
xattr -r -d com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

echo "[4/4] Launching ${APP_NAME}..."
open "${APP_PATH}"

echo ""
echo "=== Done. ${APP_NAME} is running in your menu bar. ==="
echo ""
echo "To uninstall at any time, run:"
echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/uninstall.sh | bash"
