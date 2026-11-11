#!/bin/bash
# Drive Wierdr on the physical iPad: screenshots, taps, typing, UI tree,
# orientation. See docs/BUILD.md.
#
#   scripts/ipad.sh start              build (once) and launch WebDriverAgent (USB or network)
#   scripts/ipad.sh stop               stop WebDriverAgent and the port forward
#   scripts/ipad.sh status             is WDA up, and over which link
#   scripts/ipad.sh shot [file.png]    iPad screenshot, 2x pixels (devicectl; off USB via WDA)
#   scripts/ipad.sh tree               accessibility tree of the foreground app (points)
#   scripts/ipad.sh tap <label>        tap an element by accessibility label/id
#   scripts/ipad.sh tap-xy <x> <y>     tap at a point (points: 1600x1200 landscape)
#   scripts/ipad.sh long-press <x> <y> [ms]
#   scripts/ipad.sh swipe <x1> <y1> <x2> <y2> [ms]
#   scripts/ipad.sh type <text>        type into the focused field / terminal
#   scripts/ipad.sh orient <portrait|landscapeLeft|landscapeRight>
#   scripts/ipad.sh launch | kill      (re)start / stop Wierdr
#
# Env: DEVICE (udid or name; default: first physical iPad), WDA_DIR
# (default ~/.local/share/WebDriverAgent), TEAM (default AUL4CCB2XY), WDA_PORT (8100),
# WDA_HOST (Tailscale IP/name of the iPad; default: first iOS peer named ipad*).
# One-time on the iPad: Settings › Developer › Enable UI Automation.
#
# Workflow: `make install`, then `start`, act (tap/type/swipe), then `shot` and look
# at the result. Find targets with `tree`: labels for `tap`, frames in points for `tap-xy`.
#
# Link: if the iPad is on USB, WDA goes through `iproxy` on localhost:$WDA_PORT.
# Otherwise the script talks to WDA directly at the iPad's Tailscale address, port 8100.
# WDA has no auth, so only use it over USB or Tailscale. Over Tailscale, `start`
# needs Xcode to reach the iPad, either on the same LAN or with "Connect via network".
# Once WDA is up, taps, typing and `shot` work from anywhere on the tailnet. Off USB,
# `shot` goes through WDA, or falls back to devicectl if WDA is down. `orient` and
# `launch` always use devicectl, so they need USB or the LAN.
#
# Notes:
# - `start` may make the iPad ask for its passcode. This can't be disabled
#   while the iPad has a passcode. It only happens when WDA launches, so leave
#   WDA running: if `status` says up, don't restart it. If the iPad asks,
#   ask the person to enter the passcode.
# - The session attaches to the foreground app. It doesn't relaunch Wierdr.
# - `type` goes to whatever has keyboard focus. A terminal is someone's live
#   session, so tap the intended field first.
# - Don't open a screenshot while the command taking it is still running.
set -euo pipefail

BUNDLE_ID=pw.xff.wierdr
TEAM="${TEAM:-AUL4CCB2XY}"
WDA_DIR="${WDA_DIR:-$HOME/.local/share/WebDriverAgent}"
PORT="${WDA_PORT:-8100}"
URL=""
VIA=""
STATE="${TMPDIR:-/tmp}/wierdr-wda"
mkdir -p "$STATE"

die() { echo "ipad.sh: $*" >&2; exit 1; }

device() {
  if [ -n "${DEVICE:-}" ]; then echo "$DEVICE"; return; fi
  if [ -s "$STATE/device" ]; then cat "$STATE/device"; return; fi
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null
  python3 - "$json" > "$STATE/device" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
hw = lambda x: x.get("hardwareProperties", {})
ipads = [x for x in devs if (hw(x).get("deviceType") or "").lower() == "ipad"
         and (hw(x).get("reality") or "physical") == "physical"]
ok = [x for x in ipads if x.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
pick = ok or ipads
if pick: print(hw(pick[0]).get("udid") or pick[0]["identifier"])
PY
  rm -f "$json"
  [ -s "$STATE/device" ] || die "no physical iPad found (xcrun devicectl list devices)"
  cat "$STATE/device"
}

usb() { idevice_id -l 2>/dev/null | grep -qx "$(device)"; }

ts_host() {
  if [ -n "${WDA_HOST:-}" ]; then echo "$WDA_HOST"; return; fi
  local ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [ -x "$ts" ] || ts=tailscale
  { "$ts" status --json 2>/dev/null || echo '{}'; } | python3 -c '
import json, sys
peers = json.load(sys.stdin).get("Peer") or {}
ipads = [p for p in peers.values() if p.get("OS") == "iOS" and p.get("TailscaleIPs")
         and p.get("DNSName", "").lower().startswith("ipad")]
ipads.sort(key=lambda p: not p.get("Online"))
if ipads: print(ipads[0]["TailscaleIPs"][0])'
}

ensure_iproxy() {
  if [ -s "$STATE/iproxy.pid" ] && kill -0 "$(cat "$STATE/iproxy.pid")" 2>/dev/null; then return; fi
  iproxy "$PORT:8100" -u "$(device)" > "$STATE/iproxy.log" 2>&1 < /dev/null &
  echo $! > "$STATE/iproxy.pid"
  sleep 0.5
}

# Pick the link: USB via iproxy if the iPad is plugged in, else its Tailscale address.
resolve() {
  if usb; then
    ensure_iproxy
    URL="http://localhost:$PORT"; VIA=usb
  else
    local h; h=$(ts_host)
    [ -n "$h" ] || die "iPad is not on USB and not found in tailscale status (set WDA_HOST)"
    URL="http://$h:8100"; VIA="tailscale $h"
  fi
}

up() { curl -sf -m 3 "$URL/status" >/dev/null 2>&1; }

xcb() {
  xcodebuild -project "$WDA_DIR/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner \
    -destination "id=$(device)" -derivedDataPath "$WDA_DIR/build/DD" \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    PRODUCT_BUNDLE_IDENTIFIER=pw.xff.WebDriverAgentRunner "$@"
}

start() {
  if up; then echo "WDA already up on $URL ($VIA)"; return; fi
  [ -d "$WDA_DIR" ] || git clone --depth 1 https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
  if ! ls "$WDA_DIR"/build/DD/Build/Products/*.xctestrun >/dev/null 2>&1; then
    echo "Building WebDriverAgent…"
    xcb -allowProvisioningUpdates build-for-testing 2>&1 | grep -E "error:|\*\* TEST BUILD" || true
  fi
  stop_quiet
  local dev; dev=$(device)
  DEVICE="$dev" xcb test-without-building > "$STATE/wda.log" 2>&1 < /dev/null &
  echo $! > "$STATE/wda.pid"
  resolve
  for _ in $(seq 1 60); do
    sleep 2
    if up; then echo "WDA up on $URL ($VIA, log: $STATE/wda.log)"; return; fi
    if ! kill -0 "$(cat "$STATE/wda.pid")" 2>/dev/null; then
      tail -20 "$STATE/wda.log" >&2; die "WebDriverAgent exited"
    fi
  done
  tail -20 "$STATE/wda.log" >&2; die "WebDriverAgent did not come up"
}

stop_quiet() {
  for f in wda iproxy; do
    [ -s "$STATE/$f.pid" ] && pkill -P "$(cat "$STATE/$f.pid")" 2>/dev/null || true
    [ -s "$STATE/$f.pid" ] && kill "$(cat "$STATE/$f.pid")" 2>/dev/null || true
    rm -f "$STATE/$f.pid"
  done
  rm -f "$STATE/session"
}

# WDA session attached to whatever is in the foreground (no app relaunch).
session() {
  up || die "WDA is not running: scripts/ipad.sh start"
  if [ -s "$STATE/session" ] && curl -sf -m 5 "$URL/session/$(cat "$STATE/session")" >/dev/null 2>&1; then
    cat "$STATE/session"; return
  fi
  curl -s -m 60 -X POST "$URL/session" -H 'Content-Type: application/json' \
    -d '{"capabilities":{"alwaysMatch":{"shouldWaitForQuiescence":false}}}' |
    python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d.get("sessionId")
if not s: sys.exit("WDA: " + json.dumps(d.get("value"))[:300] + "\n(on the iPad: Settings › Developer › Enable UI Automation, then: ipad.sh stop && ipad.sh start)")
print(s)' > "$STATE/session"
  # Don't wait for the app to go idle before each query and action: a live terminal
  # never goes idle, so every tap/tree would sit out WDA's 10 s default (twice per tap).
  curl -sf -m 10 -X POST "$URL/session/$(cat "$STATE/session")/appium/settings" \
    -H 'Content-Type: application/json' \
    -d '{"settings":{"waitForIdleTimeout":0,"animationCoolOffTimeout":0}}' >/dev/null ||
    echo "ipad.sh: warning: could not set WDA idle timeouts" >&2
  cat "$STATE/session"
}

wda() { # method path [json]
  local s; s=$(session)
  curl -s -m 60 -X "$1" "$URL/session/$s$2" -H 'Content-Type: application/json' ${3:+-d "$3"} |
    python3 -c '
import json, sys
v = json.load(sys.stdin).get("value")
if isinstance(v, dict) and "error" in v: sys.exit("WDA: " + v["error"] + ": " + v.get("message", "")[:300])
if v is not None: print(v if isinstance(v, str) else json.dumps(v))'
}

touch_actions() { # x y [hold_ms] [x2 y2 move_ms]
  python3 - "$@" <<'PY'
import json, sys
a = [float(x) for x in sys.argv[1:]]
x, y = a[0], a[1]
hold = int(a[2]) if len(a) > 2 else 60
seq = [{"type": "pointerMove", "duration": 0, "x": x, "y": y}, {"type": "pointerDown", "button": 0},
       {"type": "pause", "duration": hold}]
if len(a) > 4:
    seq.append({"type": "pointerMove", "duration": int(a[5]) if len(a) > 5 else 300, "x": a[3], "y": a[4]})
seq.append({"type": "pointerUp", "button": 0})
print(json.dumps({"actions": [{"type": "pointer", "id": "f1", "parameters": {"pointerType": "touch"}, "actions": seq}]}))
PY
}

cmd="${1:-help}"; shift || true
case "$cmd" in start|status|tree|tap|tap-xy|long-press|swipe|type|kill) resolve ;; esac
case "$cmd" in
  start) start ;;
  stop) stop_quiet; echo stopped ;;
  status) if up; then echo "up ($URL via $VIA, device $(device))"; else echo down; exit 1; fi ;;
  shot)
    out="${1:-ipad-shot.png}"
    # USB: devicectl. Otherwise WDA, which also works over Tailscale; devicectl if WDA is down.
    if ! usb && [ -n "$(ts_host)" ] && { resolve; up; }; then
      curl -sf -m 60 "$URL/screenshot" | python3 -c '
import base64, json, sys
v = json.load(sys.stdin).get("value")
if not isinstance(v, str): sys.exit("WDA screenshot failed: " + json.dumps(v)[:300])
open(sys.argv[1], "wb").write(base64.b64decode(v))' "$out" || die "WDA screenshot failed ($VIA)"
    else
      xcrun devicectl device capture screenshot --device "$(device)" --destination "$out" -q --timeout 30
    fi
    echo "$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" ;;
  tree)
    s=$(session)
    curl -s -m 60 "$URL/session/$s/source?format=description" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' ;;
  tap)
    [ $# -ge 1 ] || die "tap <label>"
    q=$(python3 -c 'import json,sys; print(json.dumps({"using":"predicate string","value":"label == %s OR name == %s" % (json.dumps(sys.argv[1]), json.dumps(sys.argv[1]))}))' "$1")
    el=$(wda POST /element "$q" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ELEMENT"])')
    wda POST "/element/$el/click" >/dev/null ;;
  tap-xy) [ $# -ge 2 ] || die "tap-xy <x> <y>"; wda POST /actions "$(touch_actions "$1" "$2")" ;;
  long-press) [ $# -ge 2 ] || die "long-press <x> <y> [ms]"; wda POST /actions "$(touch_actions "$1" "$2" "${3:-800}")" ;;
  swipe) [ $# -ge 4 ] || die "swipe <x1> <y1> <x2> <y2> [ms]"; wda POST /actions "$(touch_actions "$1" "$2" 30 "$3" "$4" "${5:-300}")" ;;
  type)
    [ $# -ge 1 ] || die "type <text>"
    wda POST /wda/keys "$(python3 -c 'import json,sys; print(json.dumps({"value": list(sys.argv[1])}))' "$*")" ;;
  orient) xcrun devicectl device orientation set --device "$(device)" "${1:?portrait|landscapeLeft|landscapeRight}" -q ;;
  launch) xcrun devicectl device process launch --device "$(device)" --terminate-existing "$BUNDLE_ID" -q ;;
  kill) wda POST /wda/apps/terminate "{\"bundleId\":\"$BUNDLE_ID\"}" ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
esac
