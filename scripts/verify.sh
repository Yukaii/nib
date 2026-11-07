#!/usr/bin/env bash
# The only gate. Every step must pass; the last line is the summary.
set -euo pipefail
cd "$(dirname "$0")/.."
log=$(mktemp -d)
step() { local name=$1; shift; printf '%-10s ' "$name"
  if "$@" >"$log/$name.log" 2>&1; then echo ok; else echo FAIL; tail -40 "$log/$name.log"; echo "verify: FAILED at $name"; exit 1; fi; }

step workflow scripts/check-workflow.sh
step format swift format lint --strict --recursive Packages Apps
step test swift test --package-path Packages/NibCore
step xcodegen xcodegen generate --quiet
step mac xcodebuild -project Nib.xcodeproj -scheme NibMac -destination 'generic/platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
step ipad xcodebuild -project Nib.xcodeproj -scheme NibPad -destination 'generic/platform=iOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
tests=$(grep -Eo 'Test run with [0-9]+ tests?' "$log/test.log" | tail -1 || true)
echo "verify: ok (${tests:-tests ran}; NibMac + NibPad built)"
