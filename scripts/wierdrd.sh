#!/bin/sh
# wierdrd built from this checkout, on this Mac: for working on the daemon. Users get it
# from Homebrew (`brew install wierdbytes/apps/wierdrd`, or Wierdr sets it up when it
# connects; docs/wierdrd.md). Runs as a launchd agent of the logged-in user.
#
#   scripts/wierdrd.sh install     release build → ~/.local/share/wierdrd (+ ~/.local/bin link), LaunchAgent, start;
#                                  stops Homebrew's wierdrd service and removes the old wierdr-push agent
#   scripts/wierdrd.sh uninstall   stop and remove the LaunchAgent (the binary stays)
#   scripts/wierdrd.sh restart     restart it (after editing ~/.config/wierdr/push.json)
#   scripts/wierdrd.sh status      launchd state + `wierdrd status`
#   scripts/wierdrd.sh log         follow its log (~/Library/Logs/wierdrd.log)
#
# Without ~/.config/wierdr/push.json it goes through Wierdr's relay. Straight to APNs with
# the team's key: {"key_file": "~/.config/wierdr/AuthKey_XXXXXXXXXX.p8", "key_id": "XXXXXXXXXX",
# "team_id": "AUL4CCB2XY"} (docs/live-activity.md).
set -eu
cd "$(dirname "$0")/.."

LABEL=pw.xff.wierdr.wierdrd
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# The binary needs its resource bundle (WierdrKit_WierdrModel.bundle: programs.json) beside it.
DIR="$HOME/.local/share/wierdrd"
BIN="$DIR/wierdrd"
LINK="$HOME/.local/bin/wierdrd"
LOG="$HOME/Library/Logs/wierdrd.log"
DOMAIN="gui/$(id -u)"

# Before the rename (2026-11): wierdr-push, its agent pw.xff.wierdr.push.
OLD_LABEL=pw.xff.wierdr.push

bootout() {
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrap fails (5: I/O error) until it is.
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "$DOMAIN/$1" >/dev/null 2>&1 || break; sleep 0.5; done
}

install() {
  (cd Packages/WierdrKit && swift build -c release --product wierdrd 2>&1 | grep -E "error|Compiling|Build complete" | tail -3)
  B=$(cd Packages/WierdrKit && swift build -c release --product wierdrd --show-bin-path)
  # One daemon per Mac: two would write the same push-state.json.
  if command -v brew >/dev/null 2>&1 && [ -d "$(brew --prefix)/opt/wierdrd" ]; then
    brew services stop wierdrd >/dev/null 2>&1 || true
    echo "stopped Homebrew's wierdrd service (brew services start wierdrd to go back)"
  fi
  if [ -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" ]; then
    bootout "$OLD_LABEL"
    rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" "$HOME/.local/bin/wierdr-push"
    rm -rf "$HOME/.local/share/wierdr-push"
    echo "removed the old wierdr-push agent"
  fi
  mkdir -p "$DIR" "$(dirname "$LINK")" "$(dirname "$PLIST")"
  rm -rf "$DIR/wierdrd" "$DIR"/*.bundle
  cp "$B/wierdrd" "$BIN"
  cp -R "$B"/*.bundle "$DIR/"
  ln -sf "$BIN" "$LINK"
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
  bootout "$LABEL"
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "installed: $BIN ($("$BIN" --version)), $PLIST (log: $LOG)"
}

case "${1:-}" in
  install) install ;;
  uninstall)
    bootout "$LABEL"
    rm -f "$PLIST"
    echo "removed $PLIST" ;;
  restart) launchctl kickstart -k "$DOMAIN/$LABEL" ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =|last exit" || echo "not loaded"
    "$BIN" status ;;
  log) tail -n 50 -f "$LOG" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
