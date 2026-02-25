#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building ClaudeMonitor..."
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -configuration Debug build 2>&1 | tail -5

APP=$(find ~/Library/Developer/Xcode/DerivedData/ClaudeMonitor-*/Build/Products/Debug/ClaudeMonitor.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    echo "Build failed: app not found"
    exit 1
fi

echo "Launching $APP"
open "$APP"
