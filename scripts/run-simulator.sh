#!/bin/bash
# Build the app and run it in the iOS Simulator.
# Usage: scripts/run-simulator.sh ["iPhone 17 Pro"]
set -euo pipefail
cd "$(dirname "$0")/../ios"
DEVICE="${1:-iPhone 17 Pro}"

xcodebuild -project Locis.xcodeproj -scheme Locis -configuration Debug \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO build | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl terminate "$DEVICE" studio.curateddesign.Locis 2>/dev/null || true
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/Locis.app
xcrun simctl launch "$DEVICE" studio.curateddesign.Locis
