#!/bin/bash
# Drive Wierdr on a physical iPad or iPhone: screenshots, taps, typing, UI tree,
# orientation, (re)install. Use it through `scripts/ipad.sh` or `scripts/iphone.sh`
# (they set DEVICE_KIND); see docs/BUILD.md.
#
#   start              build (once) and launch WebDriverAgent on the device (USB or LAN)
#   stop               stop WebDriverAgent and the port forward
#   status             is WDA up, and over which link
#   shot [file.png]    screenshot in device pixels (devicectl; off USB via WDA)
#   tree               accessibility tree of the foreground app (points)
#   tap <label>        tap an element by accessibility label/id
#   tap-xy <x> <y>     tap at a point (points: iPad 1600x1200 landscape, iPhone 428x926 portrait)
#   long-press <x> <y> [ms]
#   swipe <x1> <y1> <x2> <y2> [ms]
#   type <text>        type into the focused field / terminal
#   orient <portrait|landscapeLeft|landscapeRight>
#   launch | kill      (re)start / stop Wierdr
#   install [--ota] [ipa]  install dist/Wierdr.ipa (or a .app/.ipa) and launch it: devicectl
#                      when the device is reachable (USB/LAN), else (or with --ota) over the
#                      tailnet: the install page (scripts/ota.sh) opened by WDA, Install tapped
#
# Env: DEVICE (udid or name; default: first physical device of the kind), WDA_DIR
# (default ~/.local/share/WebDriverAgent), TEAM (default AUL4CCB2XY), WDA_PORT (local
# forward: 8100 iPad, 8101 iPhone), WDA_HOST (Tailscale IP/name; default: first iOS
# peer named ipad*/iphone*).
# One-time on the device: Settings › Developer › Enable UI Automation.
#
# Workflow: `make install` / `make install-iphone` (or `install` here), then `start`,
# act (tap/type/swipe), then `shot` and look at the result. Find targets with `tree`:
# labels for `tap`, frames in points for `tap-xy`.
#
# Link: if the device is on USB, WDA goes through `iproxy` on localhost:$WDA_PORT.
# Otherwise the script talks to WDA directly at the device's Tailscale address, port
# 8100. WDA has no auth, so only use it over USB or Tailscale. `start` needs Xcode to
# reach the device: USB, the same LAN, or "Connect via network". Once WDA is up,
# taps, typing, `shot`, `orient`, `launch` and `install` work from anywhere on the
# tailnet (devicectl is used instead whenever it can reach the device).
#
# Notes:
# - `start` may make the device ask for its passcode. This can't be disabled
#   while it has a passcode. It only happens when WDA launches, so leave
#   WDA running: if `status` says up, don't restart it. If the device asks,
#   ask the person to enter the passcode.
# - The session attaches to the foreground app. It doesn't relaunch Wierdr.
# - `type` goes to whatever has keyboard focus. A terminal is someone's live
#   session, so tap the intended field first.
# - Don't open a screenshot while the command taking it is still running.
# - iPad and iPhone can run WDA at the same time (separate state and ports).
set -euo pipefail

KIND="${DEVICE_KIND:-}"
case "$KIND" in
  ipad) NAME=iPad; PREFIX=ipad; STATE="${TMPDIR:-/tmp}/wierdr-wda"; PORT="${WDA_PORT:-8100}" ;;
  iphone) NAME=iPhone; PREFIX=iphone; STATE="${TMPDIR:-/tmp}/wierdr-wda-iphone"; PORT="${WDA_PORT:-8101}" ;;
  *) echo "device.sh: run scripts/ipad.sh or scripts/iphone.sh (DEVICE_KIND=ipad|iphone)" >&2; exit 2 ;;
esac
SCRIPT="$KIND.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=pw.xff.wierdr
TEAM="${TEAM:-AUL4CCB2XY}"
WDA_DIR="${WDA_DIR:-$HOME/.local/share/WebDriverAgent}"
URL=""
VIA=""
mkdir -p "$STATE"

die() { echo "$SCRIPT: $*" >&2; exit 1; }

device() {
  if [ -n "${DEVICE:-}" ]; then echo "$DEVICE"; return; fi
  if [ -s "$STATE/device" ]; then cat "$STATE/device"; return; fi
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null
  python3 - "$json" "$KIND" > "$STATE/device" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
hw = lambda x: x.get("hardwareProperties", {})
mine = [x for x in devs if (hw(x).get("deviceType") or "").lower() == sys.argv[2]
        and (hw(x).get("reality") or "physical") == "physical"]
ok = [x for x in mine if x.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
pick = ok or mine
if pick: print(hw(pick[0]).get("udid") or pick[0]["identifier"])
PY
  rm -f "$json"
  [ -s "$STATE/device" ] || die "no physical $NAME found (xcrun devicectl list devices)"
  cat "$STATE/device"
}

usb() { idevice_id -l 2>/dev/null | grep -qx "$(device)"; }

# CoreDevice (devicectl, Xcode) can reach the device now: USB or the same LAN.
coredevice() {
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; return 1; }
  python3 - "$json" "$(device)" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for x in devs:
    if sys.argv[2] in (x.get("identifier"), x.get("hardwareProperties", {}).get("udid"), x.get("deviceProperties", {}).get("name")):
        sys.exit(0 if x.get("connectionProperties", {}).get("tunnelState") not in (None, "unavailable") else 1)
sys.exit(1)
PY
  local ok=$?
  rm -f "$json"
  return $ok
}

ts_host() {
  if [ -n "${WDA_HOST:-}" ]; then echo "$WDA_HOST"; return; fi
  local ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [ -x "$ts" ] || ts=tailscale
  { "$ts" status --json 2>/dev/null || echo '{}'; } | python3 -c '
import json, sys
peers = json.load(sys.stdin).get("Peer") or {}
mine = [p for p in peers.values() if p.get("OS") == "iOS" and p.get("TailscaleIPs")
        and p.get("DNSName", "").lower().startswith(sys.argv[1])]
mine.sort(key=lambda p: not p.get("Online"))
if mine: print(mine[0]["TailscaleIPs"][0])' "$PREFIX"
}

ensure_iproxy() {
  if [ -s "$STATE/iproxy.pid" ] && kill -0 "$(cat "$STATE/iproxy.pid")" 2>/dev/null; then return; fi
  iproxy "$PORT:8100" -u "$(device)" > "$STATE/iproxy.log" 2>&1 < /dev/null &
  echo $! > "$STATE/iproxy.pid"
  sleep 0.5
}

# Pick the link: USB via iproxy if the device is plugged in, else its Tailscale address.
resolve() {
  if usb; then
    ensure_iproxy
    URL="http://localhost:$PORT"; VIA=usb
  else
    local h; h=$(ts_host)
    [ -n "$h" ] || die "$NAME is not on USB and not found in tailscale status (set WDA_HOST)"
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
  if ! ls "$WDA_DIR"/build/DD/Build/Products/*iphoneos*.xctestrun >/dev/null 2>&1; then
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
  up || die "WDA is not running: scripts/$SCRIPT start"
  if [ -s "$STATE/session" ] && curl -sf -m 5 "$URL/session/$(cat "$STATE/session")" >/dev/null 2>&1; then
    cat "$STATE/session"; return
  fi
  curl -s -m 60 -X POST "$URL/session" -H 'Content-Type: application/json' \
    -d '{"capabilities":{"alwaysMatch":{"shouldWaitForQuiescence":false}}}' |
    python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d.get("sessionId")
if not s: sys.exit("WDA: " + json.dumps(d.get("value"))[:300] + "\n(on the device: Settings › Developer › Enable UI Automation, then: stop && start)")
print(s)' > "$STATE/session"
  # Don't wait for the app to go idle before each query and action: a live terminal
  # never goes idle, so every tap/tree would sit out WDA's 10 s default (twice per tap).
  curl -sf -m 10 -X POST "$URL/session/$(cat "$STATE/session")/appium/settings" \
    -H 'Content-Type: application/json' \
    -d '{"settings":{"waitForIdleTimeout":0,"animationCoolOffTimeout":0}}' >/dev/null ||
    echo "$SCRIPT: warning: could not set WDA idle timeouts" >&2
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

launch() {
  if coredevice; then
    xcrun devicectl device process launch --device "$(device)" --terminate-existing "$BUNDLE_ID" -q
  else
    resolve
    wda POST /wda/apps/launch "{\"bundleId\":\"$BUNDLE_ID\"}" >/dev/null
  fi
}

# Install over the tailnet without Xcode: WDA opens the install page's
# itms-services link and taps Install in the system alert.
install_ota() {
  local ipa="$1"
  [ "$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa")" = "$ROOT/dist/Wierdr.ipa" ] ||
    die "over the tailnet only dist/Wierdr.ipa can be installed (make ipa)"
  resolve
  up || die "$NAME is not reachable by devicectl and WDA is not up (start it on USB/LAN once)"
  "$ROOT/scripts/ota.sh" >/dev/null
  local host; host=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
  local link="itms-services://?action=download-manifest&url=https://$host/wierdr/manifest.plist"
  echo "Installing over the tailnet ($VIA)…"
  wda POST /url "{\"url\":\"$link\"}" >/dev/null
  local accepted=
  for _ in $(seq 1 20); do
    sleep 1
    if wda POST /alert/accept '{"name":"Install"}' >/dev/null 2>&1 || wda POST /alert/accept '{}' >/dev/null 2>&1; then
      accepted=1; break
    fi
  done
  [ -n "$accepted" ] || die "no Install alert appeared (is the device unlocked? see: scripts/$SCRIPT shot)"
  # The download and install take a few seconds; launch once it runs.
  for _ in $(seq 1 30); do
    sleep 3
    if wda POST /wda/apps/launch "{\"bundleId\":\"$BUNDLE_ID\"}" >/dev/null 2>&1; then
      echo "Installed and launched"; return
    fi
  done
  die "installed? Wierdr did not launch within 90 s"
}

cmd="${1:-help}"; shift || true
case "$cmd" in start|status|tree|tap|tap-xy|long-press|swipe|type|kill) resolve ;; esac
case "$cmd" in
  start) start ;;
  stop) stop_quiet; echo stopped ;;
  status) if up; then echo "up ($URL via $VIA, device $(device))"; else echo down; exit 1; fi ;;
  shot)
    out="${1:-$KIND-shot.png}"
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
  orient)
    o="${1:?portrait|landscapeLeft|landscapeRight}"
    if coredevice; then
      xcrun devicectl device orientation set --device "$(device)" "$o" -q
    else
      case "$o" in portrait) w=PORTRAIT ;; landscapeLeft) w=LANDSCAPE ;; landscapeRight) w=UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT ;; *) die "orient portrait|landscapeLeft|landscapeRight" ;; esac
      resolve; wda POST /orientation "{\"orientation\":\"$w\"}" >/dev/null
    fi ;;
  launch) launch ;;
  kill) wda POST /wda/apps/terminate "{\"bundleId\":\"$BUNDLE_ID\"}" ;;
  install)
    ota=; if [ "${1:-}" = "--ota" ]; then ota=1; shift; fi
    src="${1:-$ROOT/dist/Wierdr.ipa}"
    [ -e "$src" ] || die "no $src (make ipa)"
    if [ -z "$ota" ] && coredevice; then
      xcrun devicectl device install app --device "$(device)" "$src" >/dev/null
      launch
      echo "Installed and launched (devicectl)"
    else
      install_ota "$src"
    fi ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
esac
