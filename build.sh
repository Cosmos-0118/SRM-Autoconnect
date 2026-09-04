#!/bin/bash

# Configuration
APP_NAME="SRM Autoconnect"
BUNDLE_ID="com.srm.autoconnect"
VERSION="1.0"
BUILD_DIR="build"
# Local self-signed identity (see Keychain Access). Ad-hoc signing (-s -) has
# no stable Team ID, and macOS refuses UNUserNotificationCenter authorization
# for such apps outright — a real (even self-signed) identity is required.
SIGN_IDENTITY="SRM Autoconnect Dev"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Stop any running instance first (locks the binary and leaves a stale status
# bar icon otherwise), then clean old builds. Match on the bundle-relative path
# only, with no leading "build/": a copy of the .app restored from a backup or
# moved elsewhere is still the same app, and leaving it running means the old
# binary keeps handling the network while the freshly built one sits idle.
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Compile Swift files
echo "Compiling Swift files..."
swiftc \
  -target $(uname -m)-apple-macosx13.0 \
  App/*.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

if [ $? -ne 0 ]; then
  echo "Compilation failed."
  exit 1
fi

# Copy Info.plist and app icon
cp Info.plist "${CONTENTS_DIR}/Info.plist"
cp Assets/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"

# Create PkgInfo
echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Re-sign after Info.plist/PkgInfo are in place so the bundle identity is
# sealed correctly, using the real local identity (see SIGN_IDENTITY above).
codesign --force --deep -s "$SIGN_IDENTITY" "$APP_DIR"

echo "Build successful! App created at: ${APP_DIR}"

# Launch it
open "$APP_DIR"
