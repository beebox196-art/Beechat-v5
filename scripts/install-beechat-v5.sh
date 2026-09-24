#!/bin/bash
# BeeChat-V5 — Side-by-side install script
#
# Builds release, assembles a NEW bundle "BeeChat-V5.app" with distinct
# CFBundleName / CFBundleDisplayName / CFBundleVersion, installs it to
# /Applications/BeeChat-V5.app, and ad-hoc signs it.
#
# SIDE-BY-SIDE SAFE: leaves /Applications/BeeChatApp.app (the Aug-7 live
# rollback) BYTE-UNCHANGED. The script refuses to run if that rollback
# is missing, or if its binary sha256 does not match the pinned Aug-7
# value. The install destination is hardcoded and the script aborts if
# it ever resolves to anything that could touch the rollback.
#
# Do NOT modify release.sh or build-and-install.sh — this script does
# not touch them, and the standing release path must stay intact.
#
# Bundle identity (per Adam, 2026-09-24):
#   CFBundleName              = "BeeChat-V5"
#   CFBundleDisplayName       = "BeeChat-V5"
#   CFBundleShortVersionString = "0.9.5l"     (same feature version)
#   CFBundleVersion           = "2026.09.24a" (distinct build marker)
#   CFBundleExecutable        = "BeeChatApp"  (binary name unchanged)
#   CFBundleIdentifier        = "com.beebox.beechat" (unchanged — do not orphan data)
#
# Usage:
#   ./scripts/install-beechat-v5.sh
#
# Exit codes:
#   0  success
#   1  pre-flight guard failed
#   2  build failed
#   3  staging failed
#   4  install failed
#   5  sign / verify failed
#   6  post-flight guard failed (rollback drifted)

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration (no overrides on purpose — keep this script deliberately rigid)
# -----------------------------------------------------------------------------

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source bundle template (untracked, lives in the repo worktree).
TEMPLATE_BUNDLE_NAME="BeeChatApp.app"
TEMPLATE_BUNDLE="$REPO/$TEMPLATE_BUNDLE_NAME"

# Destination — MUST be /Applications/BeeChat-V5.app.
# The Aug-7 live rollback is /Applications/BeeChatApp.app.
NEW_BUNDLE_NAME="BeeChat-V5.app"
APP_DST="/Applications/$NEW_BUNDLE_NAME"

# Rollback that MUST NOT be touched.
ROLLBACK_BUNDLE="/Applications/BeeChatApp.app"
ROLLBACK_BINARY="$ROLLBACK_BUNDLE/Contents/MacOS/BeeChatApp"
ROLLBACK_PINNED_SHA256="b92602befc722f507f17a9363768d7a0895b1b2c68e97b1fd2cb3c3183cdf9e8"

# Identity values written into the new bundle's Info.plist.
BUNDLE_NAME="BeeChat-V5"
BUNDLE_DISPLAY_NAME="BeeChat-V5"
BUNDLE_SHORT_VERSION="0.9.5l"
BUNDLE_BUILD="2026.09.24a"
# CFBundleExecutable stays "BeeChatApp" — the binary file is not renamed.
BUNDLE_EXECUTABLE="BeeChatApp"
# CFBundleIdentifier is intentionally NOT changed.

# Staging location — assemble the bundle here before promoting to /Applications.
STAGING_ROOT="$(mktemp -d -t beechat-v5-staging)"
STAGING_BUNDLE="$STAGING_ROOT/$NEW_BUNDLE_NAME"

cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

log()  { printf '→ %s\n' "$*"; }
fail() { printf '✗ FATAL: %s\n' "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Pre-flight guards — refuse to run if the rollback is missing or drifted
# -----------------------------------------------------------------------------

log "Pre-flight: verifying rollback is intact before doing anything else"

if [ ! -d "$ROLLBACK_BUNDLE" ]; then
    fail "rollback bundle not found at $ROLLBACK_BUNDLE — refusing to proceed" 1
fi
if [ ! -f "$ROLLBACK_BINARY" ]; then
    fail "rollback binary not found at $ROLLBACK_BINARY — refusing to proceed" 1
fi

ROLLBACK_ACTUAL_SHA256="$(shasum -a 256 "$ROLLBACK_BINARY" | awk '{print $1}')"
if [ "$ROLLBACK_ACTUAL_SHA256" != "$ROLLBACK_PINNED_SHA256" ]; then
    fail "rollback binary sha256 drifted from pinned Aug-7 value — refusing to proceed.
  pinned:   $ROLLBACK_PINNED_SHA256
  actual:   $ROLLBACK_ACTUAL_SHA256
  path:     $ROLLBACK_BINARY
This script will not touch /Applications/BeeChatApp.app, but if you see this
message it means something else modified the rollback before we ran. Investigate
before re-running." 1
fi
log "rollback binary sha256 matches pinned Aug-7 value ($ROLLBACK_PINNED_SHA256)"

# Source-template guard: must exist and must not be the rollback.
if [ ! -d "$TEMPLATE_BUNDLE" ]; then
    fail "template bundle not found at $TEMPLATE_BUNDLE" 1
fi
if [ "$(cd "$TEMPLATE_BUNDLE" && pwd -P)" = "$(cd "$ROLLBACK_BUNDLE" && pwd -P 2>/dev/null || echo NOMATCH)" ]; then
    fail "template path resolved to the rollback — refusing to proceed" 1
fi

# Destination guards: hardcoded and disjoint from rollback.
if [ "$APP_DST" = "$ROLLBACK_BUNDLE" ]; then
    fail "destination equals rollback — refusing to proceed" 1
fi
if [[ "$APP_DST" == *"$ROLLBACK_BUNDLE"* ]]; then
    fail "destination contains rollback path — refusing to proceed" 1
fi
if [[ "$APP_DST" != "/Applications/$NEW_BUNDLE_NAME" ]]; then
    fail "destination is not /Applications/$NEW_BUNDLE_NAME — refusing to proceed" 1
fi

# Belt-and-braces: never let `rsync --delete` target /Applications.
# We never use --delete, but verify the script source has no such call.
if grep -nE -- '--delete[[:space:]]' "$0" | grep -qE '/Applications[[:space:]]*$|/Applications/"?[[:space:]]*$'; then
    fail "self-check failed: script contains a 'rsync --delete' against /Applications" 1
fi

log "all pre-flight guards passed"

# -----------------------------------------------------------------------------
# Build release
# -----------------------------------------------------------------------------

log "Building release: swift build -c release"
cd "$REPO"
if ! swift build -c release; then
    fail "swift build -c release failed" 2
fi

RELEASE_BINARY="$REPO/.build/arm64-apple-macosx/release/$BUNDLE_EXECUTABLE"
if [ ! -f "$RELEASE_BINARY" ]; then
    fail "release binary not found at $RELEASE_BINARY" 2
fi
log "release binary: $RELEASE_BINARY ($(wc -c <"$RELEASE_BINARY" | awk '{print $1}') bytes)"

# -----------------------------------------------------------------------------
# Assemble new bundle in staging
# -----------------------------------------------------------------------------

log "Assembling $NEW_BUNDLE_NAME in $STAGING_ROOT"
cp -R "$TEMPLATE_BUNDLE" "$STAGING_BUNDLE"

# Replace the binary with the freshly-built release one.
STAGE_BINARY="$STAGING_BUNDLE/Contents/MacOS/$BUNDLE_EXECUTABLE"
cp -f "$RELEASE_BINARY" "$STAGE_BINARY"
log "staged binary sha256: $(shasum -a 256 "$STAGE_BINARY" | awk '{print $1}')"

# Update Info.plist identity. CFBundleIdentifier is intentionally not changed.
STAGE_PLIST="$STAGING_BUNDLE/Contents/Info.plist"
[ -f "$STAGE_PLIST" ] || fail "staged Info.plist missing: $STAGE_PLIST"

plutil -replace CFBundleName              -string "$BUNDLE_NAME"           "$STAGE_PLIST"
plutil -replace CFBundleDisplayName       -string "$BUNDLE_DISPLAY_NAME"    "$STAGE_PLIST"
plutil -replace CFBundleShortVersionString -string "$BUNDLE_SHORT_VERSION" "$STAGE_PLIST"
plutil -replace CFBundleVersion           -string "$BUNDLE_BUILD"          "$STAGE_PLIST"

# Confirm CFBundleIdentifier did not change. If it did, abort before signing/install.
ACTUAL_ID="$(plutil -extract CFBundleIdentifier raw "$STAGE_PLIST")"
EXPECTED_ID="com.beebox.beechat"
if [ "$ACTUAL_ID" != "$EXPECTED_ID" ]; then
    fail "CFBundleIdentifier drifted (expected '$EXPECTED_ID', got '$ACTUAL_ID') — aborting before install" 3
fi
log "CFBundleIdentifier preserved: $ACTUAL_ID"

# Confirm CFBundleExecutable stays "BeeChatApp".
ACTUAL_EXE="$(plutil -extract CFBundleExecutable raw "$STAGE_PLIST")"
if [ "$ACTUAL_EXE" != "$BUNDLE_EXECUTABLE" ]; then
    fail "CFBundleExecutable drifted (expected '$BUNDLE_EXECUTABLE', got '$ACTUAL_EXE') — aborting before install" 3
fi
log "CFBundleExecutable preserved: $ACTUAL_EXE"

# -----------------------------------------------------------------------------
# Install: stage → /Applications/BeeChat-V5.app
#
# IMPORTANT: rsync destination is the new bundle directory only — never
# /Applications/. No --delete. The new bundle directory is unique to this
# script, so there is no risk of sweeping other apps.
# -----------------------------------------------------------------------------

log "Installing to $APP_DST"
mkdir -p "/Applications"

# If a previous run left an old BeeChat-V5.app behind, remove it (and ONLY it)
# before rsync. The path is hardcoded and disjoint from $ROLLBACK_BUNDLE.
if [ -e "$APP_DST" ] || [ -L "$APP_DST" ]; then
    log "removing prior $APP_DST before reinstall"
    rm -rf "$APP_DST"
fi

rsync -a "$STAGING_BUNDLE/" "$APP_DST/"

# -----------------------------------------------------------------------------
# Ad-hoc sign and verify
# -----------------------------------------------------------------------------

log "Ad-hoc signing $APP_DST"
if ! codesign --force --deep --sign - "$APP_DST"; then
    fail "codesign --force --deep --sign - failed on $APP_DST" 5
fi

log "Verifying signature"
if ! codesign --verify --verbose=2 "$APP_DST"; then
    fail "codesign --verify failed on $APP_DST" 5
fi

# -----------------------------------------------------------------------------
# Post-flight: rollback must still match the pinned sha256
# -----------------------------------------------------------------------------

log "Post-flight: re-checking rollback sha256"
POST_ROLLBACK_SHA256="$(shasum -a 256 "$ROLLBACK_BINARY" | awk '{print $1}')"
if [ "$POST_ROLLBACK_SHA256" != "$ROLLBACK_PINNED_SHA256" ]; then
    fail "rollback binary sha256 changed during install — aborting.
  pinned: $ROLLBACK_PINNED_SHA256
  actual: $POST_ROLLBACK_SHA256
  This should be impossible given this script's design. Investigate." 6
fi
log "rollback binary sha256 unchanged: $POST_ROLLBACK_SHA256"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

INSTALLED_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_DST/Contents/Info.plist")"
INSTALLED_BUILD="$(plutil -extract CFBundleVersion            raw "$APP_DST/Contents/Info.plist")"
INSTALLED_NAME="$(plutil   -extract CFBundleName              raw "$APP_DST/Contents/Info.plist")"
INSTALLED_DISPLAY="$(plutil -extract CFBundleDisplayName      raw "$APP_DST/Contents/Info.plist")"
INSTALLED_ID="$(plutil     -extract CFBundleIdentifier       raw "$APP_DST/Contents/Info.plist")"
INSTALLED_EXE="$(plutil    -extract CFBundleExecutable       raw "$APP_DST/Contents/Info.plist")"
INSTALLED_BINARY_SIZE="$(ls -lh "$APP_DST/Contents/MacOS/$INSTALLED_EXE" | awk '{print $5}')"
INSTALLED_BINARY_SHA="$(shasum -a 256 "$APP_DST/Contents/MacOS/$INSTALLED_EXE" | awk '{print $1}')"

cat <<EOF

✅ BeeChat-V5 installed (side-by-side)

   Name:           $INSTALLED_NAME
   DisplayName:    $INSTALLED_DISPLAY
   Identifier:     $INSTALLED_ID   (unchanged from rollback)
   Executable:     $INSTALLED_EXE
   Version:        $INSTALLED_VERSION
   Build:          $INSTALLED_BUILD
   Binary size:    $INSTALLED_BINARY_SIZE
   Binary sha256:  $INSTALLED_BINARY_SHA
   Path:           $APP_DST
   Signed:         yes (ad-hoc; codesign --verify passed)

   Rollback at $ROLLBACK_BUNDLE is BYTE-UNCHANGED.
   Do not launch both apps at the same time — they share
   ~/Library/Application Support/BeeChat/BeeChat.sqlite.

   Launch: open $APP_DST
EOF
