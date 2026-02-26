#!/bin/bash
# uninstall.sh — Remove Media Mirror
set -euo pipefail

INSTALL_DIR="${1:-/opt/media-mirror}"

echo "Media Mirror — Uninstaller"
echo "This will stop all processes and remove $INSTALL_DIR"
read -rp "Continue? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || exit 0

# Stop LaunchAgents
if [[ "$(uname)" == "Darwin" ]]; then
    launchctl unload ~/Library/LaunchAgents/com.media-mirror.runner.plist 2>/dev/null || true
    launchctl unload ~/Library/LaunchAgents/com.media-mirror.dashboard.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.media-mirror.runner.plist
    rm -f ~/Library/LaunchAgents/com.media-mirror.dashboard.plist
    echo "✅ LaunchAgents removed"
fi

# Kill processes
pkill -f "$INSTALL_DIR/media-mirror.sh" 2>/dev/null || true
pkill -f "$INSTALL_DIR/dashboard/server.py" 2>/dev/null || true

# Remove crontab entries
(crontab -l 2>/dev/null | grep -v media-mirror) | crontab - 2>/dev/null || true

# Remove install directory
read -rp "Remove $INSTALL_DIR and all data? [y/N] " yn2
if [[ "$yn2" =~ ^[Yy]$ ]]; then
    sudo rm -rf "$INSTALL_DIR"
    echo "✅ $INSTALL_DIR removed"
else
    echo "ℹ️  $INSTALL_DIR preserved"
fi

echo "Done."
