#!/usr/bin/env bash
# Captures README screenshots from the iOS Simulator using Demo Mode.
#
# Demo Mode never starts TDLib, so the app makes no network requests and
# shows only the fictional data in fixtures/demo.json.
#
# Usage: scripts/screenshots/capture.sh ["iPhone 17 Pro"]
# Output: docs/screenshots/*.png (downscaled to 1x)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:-iPhone 17 Pro}"
FIXTURES="$ROOT/scripts/screenshots/fixtures/demo.json"
OUT="$ROOT/docs/screenshots"
DERIVED="${DERIVED_DATA:-$ROOT/build/screenshots}"
BUNDLE_ID="com.telegrowl.Telegrowl"
SETTLE="${SETTLE_SECONDS:-4}"

mkdir -p "$OUT"

echo "==> Building Debug for $DEVICE"
xcodebuild -scheme Telegrowl -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" -quiet build

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Telegrowl.app"
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
sys.exit("simulator not found: " + name)
' "$DEVICE")"

echo "==> Preparing simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork 5g \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" "$APP"

# shot <name> [KEY=VALUE ...] — launch with demo env vars, wait, capture
shot() {
  local name="$1"; shift
  local env_args=(SIMCTL_CHILD_TELEGROWL_DEMO_FIXTURES="$FIXTURES")
  for kv in "$@"; do env_args+=("SIMCTL_CHILD_TELEGROWL_DEMO_$kv"); done

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  env_args+=(SIMCTL_CHILD_TELEGROWL_DEMO_CLOCK="9:41")
  env "${env_args[@]}" xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo >/dev/null
  sleep "$SETTLE"

  local raw="$OUT/.$name.raw.png"
  xcrun simctl io "$UDID" screenshot "$raw" >/dev/null 2>&1
  # Downscale from the device's 3x to 1x points
  local height
  height=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/ {print int($2 / 3)}')
  sips -Z "$height" "$raw" --out "$OUT/$name.png" >/dev/null
  rm -f "$raw"
  echo "    $OUT/$name.png"
}

echo "==> Capturing"
shot chats AUTOLOGIN=1
shot conversation AUTOLOGIN=1 OPEN_CHAT=910001
shot dictation AUTOLOGIN=1 OPEN_CHAT=910001 DICTATION=text \
  "TRANSCRIPT=Tell Mia I'm about fifteen minutes away and I'll grab coffee"
shot voice AUTOLOGIN=1 OPEN_CHAT=910001 DICTATION=voice \
  "TRANSCRIPT=What's the weather like at the trailhead tomorrow morning"
shot settings AUTOLOGIN=1 SETTINGS=1

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear
python3 "$ROOT/scripts/screenshots/strip_png_metadata.py" "$OUT"/*.png
echo "==> Done"
