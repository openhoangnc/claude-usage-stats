#!/bin/bash
set -e

APP_NAME="ClaudeUsageStats"
APP_PATH="/Applications/${APP_NAME}.app"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.openhoangnc.claudeusagestats.plist"

echo "=== Uninstalling ${APP_NAME} ==="

# Unregister login item via the app binary (handles SMAppService + LaunchAgent).
if [ -x "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]; then
    "${APP_PATH}/Contents/MacOS/${APP_NAME}" --cleanup-login-item 2>/dev/null || true
fi

if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "--> Stopping ${APP_NAME}..."
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
fi

if [ -f "${PLIST_PATH}" ]; then
    echo "--> Removing LaunchAgent..."
    launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
    rm -f "${PLIST_PATH}"
fi

if [ -d "${APP_PATH}" ]; then
    echo "--> Removing ${APP_PATH}..."
    rm -rf "${APP_PATH}"
fi

echo "=== ${APP_NAME} removed. ==="
