#!/bin/bash
# install-helper.sh — Development-mode installer for the Kjol privileged helper.
#
# SMJobBless requires Developer ID code signing, which we don't have yet.
# This script installs the helper manually as a LaunchDaemon — same end state
# SMJobBless would produce. Also installs a companion LaunchDaemon that runs
# `caffeinate -u -i -s` under launchd, giving always-on "forever unless
# manually disabled" semantics. Requires sudo (prompts once).
#
# Usage: sudo ./install-helper.sh [--uninstall]

set -e

LABEL="com.lappier.kjol.helper"
APP="/Applications/Kjol.app"
SRC_BIN="$APP/Contents/Library/LaunchDaemons/$LABEL"
DST_BIN="/Library/PrivilegedHelperTools/$LABEL"
DST_PLIST="/Library/LaunchDaemons/$LABEL.plist"

CAFFEINATE_LABEL="com.lappier.kjol.caffeinate"
CAFFEINATE_PLIST="/Library/LaunchDaemons/$CAFFEINATE_LABEL.plist"
CAFFEINATE_BUNDLE_PLIST="$APP/Contents/Library/LaunchDaemons/$CAFFEINATE_LABEL.plist"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo: sudo $0 $*"
    exit 1
fi

if [ "$1" = "--uninstall" ]; then
    launchctl bootout system/"$LABEL" 2>/dev/null || true
    launchctl bootout system/"$CAFFEINATE_LABEL" 2>/dev/null || true
    rm -f "$DST_BIN" "$DST_PLIST" "$CAFFEINATE_PLIST"
    echo "✅ Helper and caffeinate job uninstalled."
    exit 0
fi

if [ ! -f "$SRC_BIN" ]; then
    echo "❌ Helper binary not found at $SRC_BIN — build/install the app first."
    exit 1
fi

# Stop any existing jobs
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl bootout system/"$CAFFEINATE_LABEL" 2>/dev/null || true

# Install helper binary
mkdir -p /Library/PrivilegedHelperTools
cp "$SRC_BIN" "$DST_BIN"
chown root:wheel "$DST_BIN"
chmod 755 "$DST_BIN"

# Install caffeinate job plist from app bundle, if present.
if [ -f "$CAFFEINATE_BUNDLE_PLIST" ]; then
    mkdir -p /Library/LaunchDaemons /var/log
    cp "$CAFFEINATE_BUNDLE_PLIST" "$CAFFEINATE_PLIST"
    chown root:wheel "$CAFFEINATE_PLIST"
    chmod 644 "$CAFFEINATE_PLIST"
fi

# Write helper LaunchDaemon plist
cat > "$DST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DST_BIN</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/var/log/kjol-helper.out.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/kjol-helper.err.log</string>
</dict>
</plist>
EOF
chown root:wheel "$DST_PLIST"
chmod 644 "$DST_PLIST"

# Load helper
launchctl bootstrap system "$DST_PLIST"

# Start caffeinate job if its plist is present.
if [ -f "$CAFFEINATE_PLIST" ]; then
    launchctl bootstrap system "$CAFFEINATE_PLIST" 2>/dev/null || launchctl load "$CAFFEINATE_PLIST" 2>/dev/null || true
    launchctl kickstart -k system/"$CAFFEINATE_LABEL" 2>/dev/null || true
fi

sleep 1
if launchctl print system/"$LABEL" >/dev/null 2>&1; then
    echo "✅ Kjol helper installed and running (system/$LABEL)."
else
    echo "⚠️  Helper installed but not confirmed running. Check /var/log/kjol-helper.err.log"
    exit 1
fi

