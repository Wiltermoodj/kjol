#!/bin/bash
# build-kjol.sh — Build the Kjol app, helper, and unified installer package.
#
# Usage:
#   ./build-kjol.sh              Build app and generate Kjol.pkg installer in project root
#   ./build-kjol.sh --install    Build and install via Kjol.pkg (prompts for admin via sudo)
#   ./build-kjol.sh --uninstall  Completely uninstall Kjol and the helper daemon
#
# The resulting Kjol.pkg is a single-file unified macOS installer that installs
# Kjol.app to /Applications, configures and bootstraps the privileged helper LaunchDaemon
# in /Library/LaunchDaemons, and launches the app automatically.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Kjol.app"
HELPER_DIR="$APP_DIR/Contents/Library/LaunchDaemons"
HELPER_LABEL="com.lappier.kjol.helper"
OUTPUT_PKG="$PROJECT_DIR/Kjol.pkg"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Kjol/Info.plist" 2>/dev/null || echo "1.0.0")"

# Handle --uninstall flag directly
if [ "$1" = "--uninstall" ]; then
    exec "$PROJECT_DIR/uninstall-kjol.sh"
fi

echo "=== Kjol Unified Build ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ 1. Building KjolHelper (privileged daemon)..."
swiftc -O \
    -framework IOKit \
    "$PROJECT_DIR/KjolHelper/main.swift" \
    "$PROJECT_DIR/KjolHelper/SMC.swift" \
    "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" \
    -o "$BUILD_DIR/KjolHelper"

echo "→ 2. Building Kjol (menu-bar app)..."
swiftc -O \
    -framework SwiftUI -framework AppKit -framework Security -framework CoreFoundation \
    "$PROJECT_DIR/Kjol/"*.swift \
    "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" \
    -o "$BUILD_DIR/Kjol"

echo "→ 3. Assembling app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$HELPER_DIR"

cp "$BUILD_DIR/Kjol" "$APP_DIR/Contents/MacOS/Kjol"
cp "$BUILD_DIR/KjolHelper" "$HELPER_DIR/$HELPER_LABEL"
cp "$PROJECT_DIR/Kjol/helper.plist" "$HELPER_DIR/$HELPER_LABEL.plist"
cp "$PROJECT_DIR/Kjol/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" "$APP_DIR/Contents/Resources/"

chmod +x "$APP_DIR/Contents/MacOS/Kjol"
chmod +x "$HELPER_DIR/$HELPER_LABEL"

echo "→ 4. Ad-hoc code signing components..."
codesign -f -s - --options runtime "$HELPER_DIR/$HELPER_LABEL"
codesign -f -s - --options runtime "$APP_DIR/Contents/MacOS/Kjol"
codesign -f -s - --options runtime "$APP_DIR"

echo "→ 5. Staging package payload..."
PKG_ROOT="$BUILD_DIR/pkg-root"
SCRIPTS_DIR="$BUILD_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$SCRIPTS_DIR"
mkdir -p "$PKG_ROOT/Applications"
mkdir -p "$PKG_ROOT/Library/PrivilegedHelperTools"
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$SCRIPTS_DIR"

# Copy App to /Applications
cp -R "$APP_DIR" "$PKG_ROOT/Applications/Kjol.app"

# Copy Helper to /Library/PrivilegedHelperTools (using the codesigned binary)
cp "$HELPER_DIR/$HELPER_LABEL" "$PKG_ROOT/Library/PrivilegedHelperTools/$HELPER_LABEL"
chmod 755 "$PKG_ROOT/Library/PrivilegedHelperTools/$HELPER_LABEL"

# Copy Plist to /Library/LaunchDaemons
cp "$PROJECT_DIR/Kjol/helper.plist" "$PKG_ROOT/Library/LaunchDaemons/$HELPER_LABEL.plist"
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/$HELPER_LABEL.plist"

# Generate postinstall script
cat << 'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
set -e

HELPER_LABEL="com.lappier.kjol.helper"
DST_BIN="/Library/PrivilegedHelperTools/$HELPER_LABEL"
DST_PLIST="/Library/LaunchDaemons/$HELPER_LABEL.plist"
STATE_DIR="/var/db/kjol"

# Ensure correct file permissions
mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$STATE_DIR" /var/log
chown root:wheel "$DST_BIN"
chmod 755 "$DST_BIN"
chown root:wheel "$DST_PLIST"
chmod 644 "$DST_PLIST"
chmod 700 "$STATE_DIR"

# Unregister any existing daemon instance and bootstrap fresh
launchctl bootout "system/$HELPER_LABEL" 2>/dev/null || true
launchctl enable "system/$HELPER_LABEL" 2>/dev/null || true
launchctl bootstrap system "$DST_PLIST" 2>/dev/null || true
launchctl kickstart -k "system/$HELPER_LABEL" 2>/dev/null || true

# Auto-launch Kjol for the active console user
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    # If Kjol is already running, restart it to connect to the fresh helper
    sudo -u "$CONSOLE_USER" pkill -x "Kjol" 2>/dev/null || true
    sleep 0.5
    sudo -u "$CONSOLE_USER" open -a "/Applications/Kjol.app" 2>/dev/null || true
fi

exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"

echo "→ 6. Building unified installer package (Kjol.pkg v$APP_VERSION)..."
pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "com.lappier.kjol.pkg" \
    --version "$APP_VERSION" \
    --install-location "/" \
    "$OUTPUT_PKG"

# Keep a copy in build directory as well
cp "$OUTPUT_PKG" "$BUILD_DIR/Kjol.pkg"

echo "✔ Built unified installer package: $OUTPUT_PKG"

# ---------------------------------------------------------------------------
# Direct Install via --install flag
# ---------------------------------------------------------------------------
if [ "$1" = "--install" ] || [ "$1" = "--install-root" ]; then
    if [ "$1" = "--install" ] && [ "$(id -u)" -ne 0 ]; then
        echo "→ Requesting admin privileges to run installer package..."
        sudo "$0" --install-root
        exit 0
    fi

    echo "→ Installing Kjol.pkg to system..."
    installer -pkg "$OUTPUT_PKG" -target /
    echo "✔ Installation complete! Kjol is active in the menu bar."
fi

echo "=== Done ==="
