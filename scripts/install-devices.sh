#!/usr/bin/env bash
# Builds, signs, installs and launches NibPad on the paired physical iPad and
# NibMac on this Mac. The team ID is local only (never committed):
#   git config --local nib.teamId <TEAMID>     (or export NIB_TEAM_ID)
# Usage: scripts/install-devices.sh [pad|mac|both]   (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."
target=${1:-both}
team=${NIB_TEAM_ID:-$(git config --local --get nib.teamId || true)}
[[ -n $team ]] || { echo "Set the team: git config --local nib.teamId <TEAMID>" >&2; exit 1; }
sign=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic)
log=$(mktemp)
build() { if ! xcodebuild -project Nib.xcodeproj -configuration Debug "$@" "${sign[@]}" build >"$log" 2>&1; then
  grep -E "error:" "$log" | head -20; echo "build failed; full log: $log" >&2; exit 1; fi; }

xcodegen generate --quiet

if [[ $target == pad || $target == both ]]; then
  # First paired physical iPad; the iPad must be unlocked.
  udid=$(xcrun devicectl list devices 2>/dev/null |
    awk '/physical/ && /iPad/ && /available/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
  [[ -n $udid ]] || { echo "No paired, unlocked iPad found (xcrun devicectl list devices)." >&2; exit 1; }
  build -scheme NibPad -destination "platform=iOS,id=$udid" -derivedDataPath .build/device
  xcrun devicectl device install app --device "$udid" .build/device/Build/Products/Debug-iphoneos/NibPad.app >/dev/null
  xcrun devicectl device process launch --device "$udid" --terminate-existing dev.yukai.nib.pad >/dev/null
  echo "NibPad installed and launched on $udid"
fi

if [[ $target == mac || $target == both ]]; then
  # Same path and identity every time, so the Accessibility grant survives.
  build -scheme NibMac -destination 'platform=macOS' -derivedDataPath .build/xcode-signed
  osascript -e 'tell application id "dev.yukai.nib.mac" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x NibMac 2>/dev/null || true
  open .build/xcode-signed/Build/Products/Debug/NibMac.app
  echo "NibMac relaunched from .build/xcode-signed"
fi
