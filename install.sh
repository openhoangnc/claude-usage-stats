#!/bin/bash
set -e

REPO="openhoangnc/claude-usage-stats"
APP_NAME="ClaudeUsageStats"
INSTALL_DIR="/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: ${APP_NAME} is only supported on macOS."
    exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc not found. Install Xcode command-line tools: xcode-select --install"
    exit 1
fi

echo "=== Installing ${APP_NAME} ==="

# Use the current checkout if run from the repo, otherwise clone it (curl | bash).
SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
CLONED=""
if [ ! -f "${SRC_DIR}/build.sh" ] || [ ! -f "${SRC_DIR}/main.swift" ]; then
    echo "[1/4] Fetching source..."
    CLONED="$(mktemp -d)"
    trap 'rm -rf "$CLONED"' EXIT
    git clone --depth 1 "https://github.com/${REPO}.git" "${CLONED}/src"
    SRC_DIR="${CLONED}/src"
else
    echo "[1/4] Using source at ${SRC_DIR}"
fi

echo "[2/4] Building app (icon + binary)..."
( cd "${SRC_DIR}" && ./make_icon.sh >/dev/null && ./build.sh >/dev/null )

echo "[3/4] Installing to ${APP_PATH}..."
if pgrep -x "${APP_NAME}" >/dev/null; then
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
fi
rm -rf "${APP_PATH}"
cp -R "${SRC_DIR}/${APP_NAME}.app" "${INSTALL_DIR}/"
xattr -r -d com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

echo "[4/4] Launching ${APP_NAME}..."
open "${APP_PATH}"

echo ""
echo "=== Done. ${APP_NAME} is running in your menu bar. ==="
echo "On first launch it explains what it does, then macOS asks to read your"
echo "Claude Code login from the Keychain — choose \"Always Allow\"."
