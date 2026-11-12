#!/bin/sh
# wierdr-push on this Mac: the daemon behind Wierdr's agents Live Activity
# (docs/live-activity.md). Runs as a launchd agent of the logged-in user.
#
#   scripts/push-agent.sh install     release build → ~/.local/share/wierdr-push (+ ~/.local/bin link), LaunchAgent, start
#   scripts/push-agent.sh uninstall   stop and remove the LaunchAgent (the binary stays)
#   scripts/push-agent.sh restart     restart it (after editing ~/.config/wierdr/push.json)
#   scripts/push-agent.sh status      launchd state + `wierdr-push status`
#   scripts/push-agent.sh log         follow its log (~/Library/Logs/wierdr-push.log)
#
# Needs ~/.config/wierdr/push.json: {"key_file": "~/.config/wierdr/AuthKey_XXXXXXXXXX.p8",
# "key_id": "XXXXXXXXXX", "team_id": "AUL4CCB2XY"} (an APNs key of the team that signs Wierdr).
set -eu
cd "$(dirname "$0")/.."

LABEL=pw.xff.wierdr.push
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# The binary needs its resource bundle (WierdrKit_WierdrModel.bundle: programs.json) beside it.
DIR="$HOME/.local/share/wierdr-push"
BIN="$DIR/wierdr-push"
LINK="$HOME/.local/bin/wierdr-push"
LOG="$HOME/Library/Logs/wierdr-push.log"
DOMAIN="gui/$(id -u)"

install() {
  (cd Packages/WierdrKit && swift build -c release --product wierdr-push 2>&1 | grep -E "error|Compiling|Build complete" | tail -3)
  mkdir -p "$DIR" "$(dirname "$LINK")" "$(dirname "$PLIST")"
  rm -rf "$DIR/wierdr-push" "$DIR"/*.bundle
  cp Packages/WierdrKit/.build/release/wierdr-push "$BIN"
  cp -R Packages/WierdrKit/.build/release/*.bundle "$DIR/"
  ln -sf "$BIN" "$LINK"
  [ -f "$HOME/.config/wierdr/push.json" ] || echo "note: no ~/.config/wierdr/push.json yet (see the top of this script)"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "installed: $BIN, $PLIST (log: $LOG)"
}

case "${1:-}" in
  install) install ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $PLIST" ;;
  restart) launchctl kickstart -k "$DOMAIN/$LABEL" ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =|last exit" || echo "not loaded"
    "$BIN" status ;;
  log) tail -n 50 -f "$LOG" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
