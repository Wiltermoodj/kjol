#!/bin/bash
# build-kjol.sh — Build the Kjol app and helper.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Kjol.app"
HELPER_DIR="$APP_DIR/Contents/Library/LaunchDaemons"

echo "=== Kjol Build ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ Building KjolHelper..."
swiftc -O \
    -framework IOKit \
    "$PROJECT_DIR/KjolHelper/main.swift" \
    "$PROJECT_DIR/KjolHelper/SMC.swift" \
    "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" \
    -o "$BUILD_DIR/KjolHelper"

echo "→ Building Kjol app..."
swiftc -O \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Security -framework CoreFoundation \
    "$PROJECT_DIR/Kjol/main.swift" \
    "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" \
    -o "$BUILD_DIR/Kjol"

echo "→ Assembling app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$HELPER_DIR"

cp "$BUILD_DIR/Kjol" "$APP_DIR/Contents/MacOS/Kjol"
cp "$BUILD_DIR/KjolHelper" "$HELPER_DIR/com.lappier.kjol.helper"

cp "$PROJECT_DIR/Kjol/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Kjol/helper.plist" "$HELPER_DIR/com.lappier.kjol.helper.plist"

cp "$PROJECT_DIR/KjolHelper/KjolHelperProtocol.swift" "$APP_DIR/Contents/Resources/"

chmod +x "$APP_DIR/Contents/MacOS/Kjol"
chmod +x "$HELPER_DIR/com.lappier.kjol.helper"

echo "→ Ad-hoc code signing components..."
codesign -f -s - --options runtime "$HELPER_DIR/com.lappier.kjol.helper"
codesign -f -s - --options runtime "$APP_DIR/Contents/MacOS/Kjol"
codesign -f -s - --options runtime "$APP_DIR"

echo "→ Build complete: $APP_DIR"

if [ "$1" = "--install" ]; then
    echo "→ Installing to /Applications/Kjol.app..."
    rm -rf "/Applications/Kjol.app"
    cp -R "$APP_DIR" "/Applications/Kjol.app"
    echo "→ Installed. Launch with: open /Applications/Kjol.app"
    echo "→ First launch will prompt for admin credentials to install the helper."
fi

echo "=== Done ==="
