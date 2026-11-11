#!/bin/sh
# Install (and launch) a built Wierdr.app (or .ipa) on a connected device.
# usage: scripts/install-device.sh <path/to/Wierdr.app|.ipa> [udid-or-name|ipad|iphone]
# Without a device argument it picks the first connected iPad; `iphone` picks
# the first iPhone.
set -eu
APP="${1:?usage: install-device.sh <Wierdr.app> [device|ipad|iphone]}"
DEVICE="${2:-}"
KIND=ipad
case "$DEVICE" in ipad|iphone) KIND=$DEVICE; DEVICE= ;; esac
if [ -z "$DEVICE" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE=$(python3 - "$JSON" "$KIND" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = sys.argv[2]
devs = d.get("result", {}).get("devices", [])
def hw(x): return x.get("hardwareProperties", {})
def kind(x): return (hw(x).get("deviceType") or "").lower()
def physical(x): return (hw(x).get("reality") or "physical") == "physical"
def ok(x): return x.get("connectionProperties", {}).get("tunnelState") != "unavailable"
mine = [x for x in devs if kind(x) == want and physical(x)]
pick = [x for x in mine if ok(x)] or mine
if pick: print(pick[0]["identifier"])
PY
)
  rm -f "$JSON"
fi
if [ -z "$DEVICE" ]; then
  echo "No $KIND found. Connect it with a cable (or pair it in Xcode › Devices), unlock it, and try again." >&2
  echo "Known devices:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Installing $APP on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" pw.xff.wierdr || \
  echo "Installed. If launch failed: Settings › Privacy & Security › Developer Mode must be on, then open Wierdr from the Home Screen."
