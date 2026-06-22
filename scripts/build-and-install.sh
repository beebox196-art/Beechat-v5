#!/bin/bash
# BeeChat v5 — Build, install to /Applications, update Info.plist
# Usage: ./scripts/build-and-install.sh [version] [date]
#   version: X.Y.Z format (defaults to current VERSION file + "-dev")
#   date:    YYYY.MM.DD format (defaults to today)
#
# Examples:
#   ./scripts/build-and-install.sh                # build with current version
#   ./scripts/build-and-install.sh 0.9.3          # bump version to 0.9.3
#   ./scripts/build-and-install.sh 0.9.3 2026.06.22  # bump version + date
#
# For proper releases, use scripts/release.sh instead (tags, commits, merges).

set -e

REPO="/Users/openclaw/Projects/BeeChat-v5"
APP_NAME="BeeChatApp.app"
APP_SRC="$REPO/$APP_NAME"
APP_DST="/Applications/$APP_NAME"

cd "$REPO"

# Optional version bump
if [ -n "$1" ]; then
    VERSION="$1"
    DATE="${2:-$(date +%Y.%m.%d)}"
    echo "→ Setting version $VERSION ($DATE)"
    echo "$VERSION" > VERSION
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_SRC/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$DATE" "$APP_SRC/Contents/Info.plist"
fi

# Build
echo "→ Building..."
swift build 2>&1 | tail -3

# Copy binary into app bundle
echo "→ Updating app bundle binary"
cp -f .build/arm64-apple-macosx/debug/BeeChatApp "$APP_SRC/Contents/MacOS/BeeChatApp"

# Install to /Applications
echo "→ Installing to $APP_DST"
rsync -av --delete "$APP_SRC/" "$APP_DST/"

# Verify
INSTALLED_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_DST/Contents/Info.plist")
INSTALLED_BUILD=$(plutil -extract CFBundleVersion raw "$APP_DST/Contents/Info.plist")
BINARY_SIZE=$(ls -lh "$APP_DST/Contents/MacOS/BeeChatApp" | awk '{print $5}')

echo ""
echo "✅ BeeChat installed"
echo "   Version: $INSTALLED_VERSION"
echo "   Build:   $INSTALLED_BUILD"
echo "   Binary:  $BINARY_SIZE"
echo "   Path:    $APP_DST"
echo ""
echo "Launch: open $APP_DST"