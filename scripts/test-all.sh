#!/bin/bash
# Run every automated test: pipeline (Python), rules engine (Swift package) and
# the app's own tests in the iOS Simulator.
# Usage: scripts/test-all.sh [--skip-app]
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Pipeline tests =="
(cd pipeline && .venv/bin/pytest)

echo "== Rules engine tests =="
(cd ios/LocisKit && swift test 2>&1 | grep -E "error|✘|Test run")

if [ "${1:-}" != "--skip-app" ]; then
    echo "== App tests (iOS Simulator) =="
    (cd ios && xcodebuild -project Locis.xcodeproj -scheme Locis \
        -destination "platform=iOS Simulator,name=${LOCIS_SIMULATOR:-iPhone 17 Pro}" \
        -derivedDataPath build CODE_SIGNING_ALLOWED=NO test 2>&1 \
        | grep -E "error:|failed|TEST (SUCCEEDED|FAILED)" | sort -u)
fi
