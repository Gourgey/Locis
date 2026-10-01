#!/bin/bash
# Regenerate the synthetic demo dataset and copy it to where the app and the
# Swift tests read it. Run after changing pipeline/src/locis_pipeline/demo.py.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
pipeline/.venv/bin/locis demo --out "$OUT" > /dev/null

for target in ios/Locis/Resources/DemoData ios/LocisKit/Tests/LocisKitTests/Resources/demo; do
    rm -rf "$target"
    mkdir -p "$target"
    cp -R "$OUT"/. "$target"/
done
echo "Demo data written: $(find ios/Locis/Resources/DemoData -name '*.json' | wc -l | tr -d ' ') files"
