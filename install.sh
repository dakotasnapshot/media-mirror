#!/bin/bash
# install.sh — Media Mirror Installer
# Installs Media Mirror on the local machine (the conversion host).
set -euo pipefail

INSTALL_DIR="${1:-/opt/media-mirror}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " Media Mirror — Installer"
echo "=========================================="
echo "Install directory: $INSTALL_DIR"
echo ""

# ─── 1. Check dependencies ───────────────────────────────────────────

echo "[1/6] Checking dependencies..."

# ffmpeg
if command -v ffmpeg &>/dev/null; then
    echo "  ✅ ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
else
    echo "  ❌ ffmpeg not found."
    echo ""
    echo "  Install ffmpeg via one of these methods:"
    echo "    • Homebrew:       brew install ffmpeg"
    echo "    • Static binary:  curl -L https://evermeet.cx/ffmpeg/getrelease/zip -o /tmp/ffmpeg.zip"
    echo "                      unzip /tmp/ffmpeg.zip -d /usr/local/bin/"
    echo ""
    read -rp "  Would you like to try downloading the static binary now? [y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo "  Downloading..."
        curl -sL -o /tmp/ffmpeg.zip "https://evermeet.cx/ffmpeg/getrelease/zip"
        unzip -o /tmp/ffmpeg.zip -d /tmp/
        sudo mv /tmp/ffmpeg /usr/local/bin/ffmpeg
        sudo chmod +x /usr/local/bin/ffmpeg
        rm -f /tmp/ffmpeg.zip
        echo "  ✅ ffmpeg installed: $(ffmpeg -version 2>&1 | head -1)"
    else
        echo "  ⚠️  Please install ffmpeg and re-run this installer."
        exit 1
    fi
fi

# rsync
if command -v rsync &>/dev/null; then
    echo "  ✅ rsync: $(rsync --version 2>&1 | head -1)"
else
    echo "  ❌ rsync not found. Please install rsync."
    exit 1
fi

# python3
if command -v python3 &>/dev/null; then
    echo "  ✅ python3: $(python3 --version)"
else
    echo "  ❌ python3 not found. Please install Python 3."
    exit 1
fi

# ─── 2. Create directories ───────────────────────────────────────────

echo ""
echo "[2/6] Creating directories..."
sudo mkdir -p "$INSTALL_DIR/logs" "$INSTALL_DIR/dashboard"
sudo chown -R "$(whoami):staff" "$INSTALL_DIR"
echo "  ✅ $INSTALL_DIR"

# ─── 3. Copy files ───────────────────────────────────────────────────

echo ""
echo "[3/6] Copying files..."
cp "$SCRIPT_DIR/media-mirror.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/dashboard/server.py" "$INSTALL_DIR/dashboard/"
cp "$SCRIPT_DIR/dashboard/index.html" "$INSTALL_DIR/dashboard/"
chmod +x "$INSTALL_DIR/media-mirror.sh"

# Copy config if it doesn't already exist
if [ ! -f "$INSTALL_DIR/config.env" ]; then
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        cp "$SCRIPT_DIR/config.env" "$INSTALL_DIR/"
    else
        cp "$SCRIPT_DIR/config.example.env" "$INSTALL_DIR/config.env"
    fi
    echo "  ⚠️  Config copied to $INSTALL_DIR/config.env — please edit it!"
else
    echo "  ℹ️  Existing config.env preserved."
fi

# Init state file
if [ ! -f "$INSTALL_DIR/state.json" ]; then
    echo '{"jobs":[],"stats":{"total_files":0,"converted":0,"transferred":0,"failed":0,"skipped":0},"runner":{"status":"idle","started":"","paused":false}}' > "$INSTALL_DIR/state.json"
fi

echo "  ✅ Files installed"

# ─── 4. SSH Key ──────────────────────────────────────────────────────

echo ""
echo "[4/6] SSH key setup..."
KEY_PATH="$INSTALL_DIR/dest_key"
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "media-mirror"
    echo ""
    echo "  ──────────────────────────────────────────────"
    echo "  📋 Add this public key to your DESTINATION host:"
    echo ""
    echo "  $(cat "${KEY_PATH}.pub")"
    echo ""
    echo "  Run on the destination:"
    echo "    echo '$(cat "${KEY_PATH}.pub")' >> ~/.ssh/authorized_keys"
    echo "  ──────────────────────────────────────────────"
else
    echo "  ℹ️  SSH key already exists at $KEY_PATH"
fi

# ─── 5. LaunchAgents (macOS) ─────────────────────────────────────────

echo ""
echo "[5/6] Setting up auto-start..."
if [[ "$(uname)" == "Darwin" ]]; then
    AGENT_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$AGENT_DIR"

    # Runner
    cat > "$AGENT_DIR/com.media-mirror.runner.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.media-mirror.runner</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>${INSTALL_DIR}/media-mirror.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/logs/runner-stdout.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/logs/runner-stderr.log</string>
    <key>WorkingDirectory</key><string>${INSTALL_DIR}</string>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict>
</plist>
PLIST

    # Dashboard
    cat > "$AGENT_DIR/com.media-mirror.dashboard.plist" << PLIST2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.media-mirror.dashboard</string>
    <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>${INSTALL_DIR}/dashboard/server.py</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>EnvironmentVariables</key><dict>
        <key>STATE_FILE</key><string>${INSTALL_DIR}/state.json</string>
        <key>LOG_DIR</key><string>${INSTALL_DIR}/logs</string>
        <key>CONFIG_FILE</key><string>${INSTALL_DIR}/config.env</string>
        <key>INSTALL_DIR</key><string>${INSTALL_DIR}</string>
        <key>DASHBOARD_PORT</key><string>8080</string>
        <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/logs/dashboard-stdout.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/logs/dashboard-stderr.log</string>
    <key>WorkingDirectory</key><string>${INSTALL_DIR}/dashboard</string>
</dict>
</plist>
PLIST2

    echo "  ✅ LaunchAgents created"
    echo ""
    echo "  ⚠️  Note: On macOS, LaunchAgents may not have access to external volumes"
    echo "  due to TCC/Full Disk Access restrictions. If the runner can't read your"
    echo "  source drive, you have two options:"
    echo "    1. Use @reboot in crontab (usually inherits TCC from user session)"
    echo "    2. Grant Full Disk Access to /bin/bash in System Preferences"
    echo ""
    read -rp "  Load LaunchAgents now? [y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        launchctl load "$AGENT_DIR/com.media-mirror.dashboard.plist" 2>/dev/null || true
        launchctl load "$AGENT_DIR/com.media-mirror.runner.plist" 2>/dev/null || true
        echo "  ✅ LaunchAgents loaded"
    fi
else
    echo "  ℹ️  Non-macOS system detected. Add to your init system manually:"
    echo "    Runner:    bash $INSTALL_DIR/media-mirror.sh"
    echo "    Dashboard: python3 $INSTALL_DIR/dashboard/server.py"
fi

# ─── 6. Done ─────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo " ✅ Installation Complete!"
echo "=========================================="
echo ""
echo " Dashboard:  http://$(hostname):8080"
echo " Config:     $INSTALL_DIR/config.env"
echo " Logs:       $INSTALL_DIR/logs/"
echo ""
echo " Next steps:"
echo "   1. Edit $INSTALL_DIR/config.env with your paths"
echo "   2. Add the SSH public key to your destination host"
echo "   3. Open the dashboard and click Start"
echo ""
