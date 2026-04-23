#!/bin/bash
# BeeChat v5 — Canonical launch script
# Always launches the v5 app from the correct path
APP="/Users/openclaw/Projects/BeeChat-v5/BeeChatApp.app"
if [ -d "$APP" ]; then
    open "$APP"
else
    echo "ERROR: BeeChatApp.app not found at $APP"
    echo "Build in Xcode first, or run: swift build"
    exit 1
fi
