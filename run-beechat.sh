#!/bin/bash
# BeeChat v5 — Canonical launcher
# Always launches the /Applications copy — single source of truth.
# To update: swift build && rsync -av --delete BeeChatApp.app/ /Applications/BeeChatApp.app/
APP="/Applications/BeeChatApp.app"
if [ -d "$APP" ]; then
    open "$APP"
else
    echo "ERROR: BeeChatApp.app not found at $APP"
    echo "Build first: cd /Users/openclaw/Projects/BeeChat-v5 && swift build"
    echo "Then install: rsync -av --delete BeeChatApp.app/ /Applications/BeeChatApp.app/"
    exit 1
fi