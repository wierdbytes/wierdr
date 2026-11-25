#!/bin/bash
# Drive Wierdr in the iPhone simulator: build/install/launch, screenshots,
# taps, swipes, typing, UI tree (WebDriverAgent on the simulator).
#
#   scripts/iphone-sim.sh boot               create (once) and boot the simulator
#   scripts/iphone-sim.sh install            Debug build for the simulator + install
#   scripts/iphone-sim.sh launch [args…]     (re)launch Wierdr, e.g. `launch -demo YES`
#   scripts/iphone-sim.sh start              WebDriverAgent on the simulator (port $WDA_PORT)
#   scripts/iphone-sim.sh stop               stop WebDriverAgent
#   scripts/iphone-sim.sh shot [file.png]    screenshot (simctl, 3x pixels)
#   scripts/iphone-sim.sh tree               accessibility tree of the foreground app (points)
#   scripts/iphone-sim.sh tap <label>        tap an element by accessibility label/id
#   scripts/iphone-sim.sh tap-xy <x> <y>     tap at a point (points: 428x926 portrait)
#   scripts/iphone-sim.sh long-press <x> <y> [ms]
#   scripts/iphone-sim.sh swipe <x1> <y1> <x2> <y2> [ms]
#   scripts/iphone-sim.sh type <text>        type into the focused field / terminal
#   scripts/iphone-sim.sh orient <portrait|landscape>
#   scripts/iphone-sim.sh appearance <light|dark>
#
# The simulator always runs the newest installed iOS runtime: a SIM_NAME device on an older
# runtime is ignored, and `boot` creates a fresh one on the newest.
#
# Env: SIM_NAME (default "Wierdr iPhone 13 Pro Max"), SIM_TYPE (device type for `boot` to create,
# default iPhone-13-Pro-Max), WDA_DIR (~/.local/share/WebDriverAgent),
# WDA_PORT (8200, so it doesn't collide with the iPad's WDA on 8100).
# Launch args/env for the app: see App/Sources/WierdrApp.swift and docs/architecture/app.md
# (`-demo YES`, `-open …`, SIMCTL_CHILD_WIERDR_AUTOCONNECT=…).
set -euo pipefail

BUNDLE_ID=pw.xff.wierdr
SIM_NAME="${SIM_NAME:-Wierdr iPhone 13 Pro Max}"
SIM_TYPE="${SIM_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max}"
WDA_DIR="${WDA_DIR:-$HOME/.local/share/WebDriverAgent}"
PORT="${WDA_PORT:-8200}"
URL="http://localhost:$PORT"
STATE="${TMPDIR:-/tmp}/wierdr-simwda"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$STATE"

die() { echo "iphone-sim.sh: $*" >&2; exit 1; }

runtime() { # the newest available iOS simulator runtime
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
if not rs: sys.exit("iphone-sim.sh: no iOS simulator runtime (xcodebuild -downloadPlatform iOS)")
print(max(rs, key=lambda r: tuple(int(x) for x in r["version"].split(".")))["identifier"])'
}

udid() { # SIM_NAME on the newest runtime
  local rt; rt=$(runtime)
  xcrun simctl list devices -j | python3 -c '
import json, sys
name, rt = sys.argv[1], sys.argv[2]
for d in json.load(sys.stdin)["devices"].get(rt, []):
    if d["name"] == name and d.get("isAvailable", True): print(d["udid"]); sys.exit()' "$SIM_NAME" "$rt"
}

sim() {
  local u; u=$(udid)
  [ -n "$u" ] || die "no simulator \"$SIM_NAME\" (scripts/iphone-sim.sh boot)"
  echo "$u"
}

boot() {
  local u; u=$(udid)
  if [ -z "$u" ]; then
    u=$(xcrun simctl create "$SIM_NAME" "$SIM_TYPE" "$(runtime)")
  fi
  xcrun simctl boot "$u" 2>/dev/null || true
  open -a Simulator
  echo "$u"
}

install() {
  cd "$ROOT"
  xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath build/DerivedData \
    -skipPackagePluginValidation -skipMacroValidation -configuration Debug \
    -destination "id=$(sim)" build 2>&1 | grep -E "error:|\*\* BUILD" | cut -c1-300
  xcrun simctl install "$(sim)" build/DerivedData/Build/Products/Debug-iphonesimulator/Wierdr.app
}

up() { curl -sf -m 3 "$URL/status" >/dev/null 2>&1; }

start() {
  if up; then echo "WDA already up on $URL"; return; fi
  [ -d "$WDA_DIR" ] || git clone --depth 1 https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
  if ! ls "$WDA_DIR"/build/DDsim/Build/Products/*.xctestrun >/dev/null 2>&1; then
    echo "Building WebDriverAgent for the simulator…"
    xcodebuild -project "$WDA_DIR/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner \
      -destination "id=$(sim)" -derivedDataPath "$WDA_DIR/build/DDsim" CODE_SIGNING_ALLOWED=NO \
      build-for-testing 2>&1 | grep -E "error:|\*\* TEST BUILD" || true
  fi
  TEST_RUNNER_USE_PORT="$PORT" xcodebuild -xctestrun "$(ls "$WDA_DIR"/build/DDsim/Build/Products/*.xctestrun | head -1)" \
    -destination "id=$(sim)" test-without-building > "$STATE/wda.log" 2>&1 < /dev/null &
  echo $! > "$STATE/wda.pid"
  for _ in $(seq 1 60); do
    sleep 2
    if up; then echo "WDA up on $URL (log: $STATE/wda.log)"; return; fi
  done
  tail -20 "$STATE/wda.log" >&2; die "WebDriverAgent did not come up"
}

stop() {
  [ -s "$STATE/wda.pid" ] && { pkill -P "$(cat "$STATE/wda.pid")" 2>/dev/null || true; kill "$(cat "$STATE/wda.pid")" 2>/dev/null || true; }
  rm -f "$STATE/wda.pid" "$STATE/session"
}

session() {
  up || die "WDA is not running: scripts/iphone-sim.sh start"
  if [ -s "$STATE/session" ] && curl -sf -m 5 "$URL/session/$(cat "$STATE/session")" >/dev/null 2>&1; then
    cat "$STATE/session"; return
  fi
  curl -s -m 60 -X POST "$URL/session" -H 'Content-Type: application/json' \
    -d '{"capabilities":{"alwaysMatch":{"shouldWaitForQuiescence":false}}}' |
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("sessionId"); print(s) if s else sys.exit("WDA: "+json.dumps(d)[:300])' > "$STATE/session"
  curl -sf -m 10 -X POST "$URL/session/$(cat "$STATE/session")/appium/settings" -H 'Content-Type: application/json' \
    -d '{"settings":{"waitForIdleTimeout":0,"animationCoolOffTimeout":0}}' >/dev/null || true
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
case "$cmd" in
  boot) boot ;;
  install) install ;;
  launch) xcrun simctl terminate "$(sim)" "$BUNDLE_ID" 2>/dev/null || true
          rm -f "$STATE/session"
          xcrun simctl launch "$(sim)" "$BUNDLE_ID" "$@" ;;
  start) start ;;
  stop) stop; echo stopped ;;
  shot) out="${1:-iphone-shot.png}"; xcrun simctl io "$(sim)" screenshot "$out" >/dev/null 2>&1; echo "$out" ;;
  tree) s=$(session); curl -s -m 60 "$URL/session/$s/source?format=description" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' ;;
  tap)
    [ $# -ge 1 ] || die "tap <label>"
    q=$(python3 -c 'import json,sys; print(json.dumps({"using":"predicate string","value":"label == %s OR name == %s" % (json.dumps(sys.argv[1]), json.dumps(sys.argv[1]))}))' "$1")
    el=$(wda POST /element "$q" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ELEMENT"])')
    wda POST "/element/$el/click" >/dev/null ;;
  tap-xy) [ $# -ge 2 ] || die "tap-xy <x> <y>"; wda POST /actions "$(touch_actions "$1" "$2")" ;;
  long-press) [ $# -ge 2 ] || die "long-press <x> <y> [ms]"; wda POST /actions "$(touch_actions "$1" "$2" "${3:-800}")" ;;
  swipe) [ $# -ge 4 ] || die "swipe <x1> <y1> <x2> <y2> [ms]"; wda POST /actions "$(touch_actions "$1" "$2" 30 "$3" "$4" "${5:-300}")" ;;
  type) [ $# -ge 1 ] || die "type <text>"
        wda POST /wda/keys "$(python3 -c 'import json,sys; print(json.dumps({"value": list(sys.argv[1])}))' "$*")" ;;
  orient)
    o="${1:?portrait|landscape}"; [ "$o" = landscape ] && o=LANDSCAPE || o=PORTRAIT
    wda POST /orientation "{\"orientation\":\"$o\"}" ;;
  appearance) xcrun simctl ui "$(sim)" appearance "${1:?light|dark}" ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
esac
