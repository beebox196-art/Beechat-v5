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

# Copy SPM resource bundle into app bundle (required for MessageTemplate.html,
# Assets.xcassets, and any future resources declared in Package.swift).
# This is the primary fix for P0.0 blocker #1 — without this, Bundle.main and
# Bundle.module cannot find MessageTemplate.html at runtime.
SPM_BUNDLE=".build/arm64-apple-macosx/debug/BeeChatPersistence_BeeChatApp.bundle"
if [ -d "$SPM_BUNDLE" ]; then
    echo "→ Copying SPM resource bundle"
    mkdir -p "$APP_SRC/Contents/Resources"
    cp -R "$SPM_BUNDLE" "$APP_SRC/Contents/Resources/"
else
    echo "⚠ SPM resource bundle missing — MessageTemplate.html and other resources may not load" >&2
    echo "  Run 'swift build' first to generate the bundle" >&2
fi

# Also copy GRDB's resource bundle if present
GRDB_BUNDLE=".build/arm64-apple-macosx/debug/GRDB_GRDB.bundle"
if [ -d "$GRDB_BUNDLE" ]; then
    cp -R "$GRDB_BUNDLE" "$APP_SRC/Contents/Resources/"
fi

# Install to /Applications
echo "→ Installing to $APP_DST"
rsync -av --delete "$APP_SRC/" "$APP_DST/"

# Verify
INSTALLED_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_DST/Contents/Info.plist")
INSTALLED_BUILD=$(plutil -extract CFBundleVersion raw "$APP_DST/Contents/Info.plist")
BINARY_SIZE=$(ls -lh "$APP_DST/Contents/MacOS/BeeChatApp" | awk '{print $5}')

# Verify resource bundle
if [ -d "$APP_SRC/Contents/Resources/BeeChatPersistence_BeeChatApp.bundle" ]; then
    if [ -f "$APP_SRC/Contents/Resources/BeeChatPersistence_BeeChatApp.bundle/MessageTemplate.html" ] || [ -f "$APP_SRC/Contents/Resources/BeeChatPersistence_BeeChatApp.bundle/Contents/Resources/MessageTemplate.html" ]; then
        echo "  ✓ MessageTemplate.html found in SPM bundle"
    else
        echo "  ⚠ MessageTemplate.html NOT in SPM bundle — HTML rendering will use embedded fallback"
    fi
fi

echo ""
echo "✅ BeeChat installed"
echo "   Version: $INSTALLED_VERSION"
echo "   Build:   $INSTALLED_BUILD"
echo "   Binary:  $BINARY_SIZE"
echo "   Path:    $APP_DST"
echo ""
echo "Launch: open $APP_DST"