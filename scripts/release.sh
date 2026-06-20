#!/bin/bash
# BeeChat v5 — Release script
# Bumps version, updates Info.plist, commits, tags, updates app bundle
#
# Usage: ./scripts/release.sh <version> <date> "<release-notes>"
# Example: ./scripts/release.sh 0.9.3 2026.06.25 "FR-004 feature name"
#
# Steps performed:
#   1. Validates version format (X.Y.Z)
#   2. Updates VERSION file
#   3. Updates BeeChatApp.app/Contents/Info.plist (CFBundleShortVersionString + CFBundleVersion)
#   4. Builds the app
#   5. Copies fresh binary into BeeChatApp.app/Contents/MacOS/
#   6. Commits the version bump
#   7. Tags the release
#   8. Merges to main
#
# After running, manually verify and push: git push origin main --tags

set -e  # Exit on any error

VERSION="$1"
DATE="$2"
NOTES="$3"

# Validate inputs
if [ -z "$VERSION" ] || [ -z "$DATE" ] || [ -z "$NOTES" ]; then
    echo "Usage: $0 <version> <date> \"<release-notes>\""
    echo "Example: $0 0.9.3 2026.06.25 \"FR-004 feature name\""
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be in X.Y.Z format (got: $VERSION)"
    exit 1
fi

if ! [[ "$DATE" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
    echo "ERROR: Date must be in YYYY.MM.DD format (got: $DATE)"
    exit 1
fi

# Check we're on develop (not main)
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "develop" ]; then
    echo "ERROR: Must be on 'develop' branch to release (currently on: $BRANCH)"
    echo "Run: git checkout develop"
    exit 1
fi

# Check working tree is clean
if ! git diff-index --quiet HEAD --; then
    echo "ERROR: Working tree has uncommitted changes. Commit or stash first."
    exit 1
fi

echo "→ Bumping version to $VERSION ($DATE)"
echo "$VERSION" > VERSION

echo "→ Updating Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" BeeChatApp.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$DATE" BeeChatApp.app/Contents/Info.plist

echo "→ Building app"
swift build 2>&1 | tail -3

echo "→ Copying fresh binary into app bundle"
cp -f .build/arm64-apple-macosx/debug/BeeChatApp BeeChatApp.app/Contents/MacOS/BeeChatApp

echo "→ Committing version bump"
git add VERSION BeeChatApp.app/Contents/Info.plist .build/ 2>/dev/null || git add VERSION BeeChatApp.app/Contents/Info.plist
git commit -m "release: v$VERSION — $NOTES"

echo "→ Creating release branch and tag"
git checkout -b "release/v$VERSION"
git tag -a "v$VERSION-release" -m "v$VERSION — $NOTES"
git checkout main
git merge --no-ff "release/v$VERSION" -m "merge: v$VERSION release — $NOTES"
git tag "v$VERSION"

echo ""
echo "✅ Release v$VERSION prepared"
echo ""
echo "Next steps:"
echo "  1. Verify: git log --oneline -5 && git tag -l \"v$VERSION*\""
echo "  2. Push:    git push origin main --tags"
echo "  3. Test:    bash run-beechat.sh"
echo ""
echo "Version in app: $(plutil -extract CFBundleShortVersionString raw BeeChatApp.app/Contents/Info.plist)"
echo "Build date:     $(plutil -extract CFBundleVersion raw BeeChatApp.app/Contents/Info.plist)"
