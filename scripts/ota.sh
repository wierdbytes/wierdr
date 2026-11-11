#!/bin/sh
# Over-the-air install of dist/Wierdr.ipa (development-signed, so only on the
# team's registered devices) from this Mac, over HTTPS on its tailnet name.
#
#   scripts/ota.sh          build dist/ota/ (page, manifest, icons, ipa) and serve it at
#                           https://<this-mac>.<tailnet>.ts.net/wierdr/ (tailscale serve, tailnet only)
#   scripts/ota.sh off      stop serving /wierdr (the rest of the serve config stays)
#   scripts/ota.sh status   what is served
#
# The Tailscale app can't serve folders (sandbox), so a small static server
# (python3 http.server on 127.0.0.1:$OTA_PORT, default 8791, pid in dist/ota.pid)
# serves dist/ota and `tailscale serve` proxies /wierdr to it.
#
# On the iPhone/iPad (in the tailnet, Developer Mode on): open the URL in Safari,
# tap Install, then open Wierdr from the Home Screen. Run `make ipa` first.
#
# Only the /wierdr path is added to `tailscale serve`; other handlers (e.g. `/`)
# are left alone. It is not public (no Funnel).
set -eu
cd "$(dirname "$0")/.."

TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS=tailscale
MOUNT=/wierdr
DIR="$(pwd)/dist/ota"
IPA=dist/Wierdr.ipa
PORT="${OTA_PORT:-8791}"
PIDFILE="$(pwd)/dist/ota.pid"

stop_server() {
  if [ -s "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
}

case "${1:-}" in
  off) "$TS" serve --https=443 --set-path "$MOUNT" off || true; stop_server; echo stopped; exit ;;
  status) "$TS" serve status; [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo "server pid $(cat "$PIDFILE") on 127.0.0.1:$PORT"; exit ;;
esac

[ -f "$IPA" ] || { echo "No $IPA: run make ipa first" >&2; exit 1; }
HOST=$("$TS" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
BASE="https://$HOST$MOUNT"

rm -rf "$DIR"
mkdir -p "$DIR"
cp "$IPA" "$DIR/Wierdr.ipa"
TMP=$(mktemp -d)
unzip -q -o "$IPA" 'Payload/Wierdr.app/Info.plist' -d "$TMP"
INFO="$TMP/Payload/Wierdr.app/Info.plist"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
rm -rf "$TMP"
ICON=App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
sips -z 57 57 "$ICON" --out "$DIR/icon-57.png" >/dev/null
sips -z 512 512 "$ICON" --out "$DIR/icon-512.png" >/dev/null
STAMP=$(date +%Y%m%d%H%M%S)

cat > "$DIR/manifest.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>items</key><array><dict>
    <key>assets</key><array>
      <dict><key>kind</key><string>software-package</string><key>url</key><string>$BASE/Wierdr.ipa?v=$STAMP</string></dict>
      <dict><key>kind</key><string>display-image</string><key>url</key><string>$BASE/icon-57.png</string></dict>
      <dict><key>kind</key><string>full-size-image</string><key>url</key><string>$BASE/icon-512.png</string></dict>
    </array>
    <key>metadata</key><dict>
      <key>bundle-identifier</key><string>$BUNDLE</string>
      <key>bundle-version</key><string>$VERSION</string>
      <key>kind</key><string>software</string>
      <key>title</key><string>Wierdr $VERSION ($BUILD)</string>
    </dict>
  </dict></array>
</dict></plist>
PL

cat > "$DIR/index.html" <<HTML
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wierdr $VERSION</title>
<style>
  body { font: 17px -apple-system, system-ui, sans-serif; margin: 0; padding: 40px 24px; background: #16191d; color: #eeeeef; text-align: center; }
  img { width: 112px; height: 112px; border-radius: 26px; }
  h1 { margin: 18px 0 4px; font-size: 28px; }
  p { color: #9c9ea1; line-height: 1.45; }
  a.btn { display: inline-block; margin: 22px 0 8px; padding: 14px 34px; border-radius: 14px; background: #61afef; color: #16191d; font-weight: 600; text-decoration: none; }
  ol { text-align: left; max-width: 460px; margin: 24px auto; color: #c8c9cb; line-height: 1.5; padding-left: 22px; }
  code { color: #e5c07b; }
</style></head>
<body>
  <img src="icon-512.png" alt="">
  <h1>Wierdr</h1>
  <p>Версия $VERSION (сборка $BUILD) · $(date '+%d.%m.%Y %H:%M')</p>
  <a class="btn" href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist">Установить</a>
  <ol>
    <li>Нажми «Установить» и подтверди. Иконка появится на экране «Домой».</li>
    <li>Если iOS пишет «Ненадёжный разработчик»: Настройки › Основные › VPN и управление устройством › Apple Development: … › Доверять.</li>
    <li>В Wierdr: Add Host → <code>mentoair.local</code> или по Tailscale <code>$HOST</code>, пользователь <code>$(id -un)</code>, вход Password → Connect.</li>
    <li>Потом Settings → Install This iPhone’s Key — дальше без пароля.</li>
  </ol>
</body></html>
HTML

# Answer under both / and /wierdr/, whether or not the proxy strips the mount path.
ln -s . "$DIR/wierdr"
stop_server
nohup python3 -c '
import functools, http.server, sys
H = http.server.SimpleHTTPRequestHandler
H.extensions_map = {**H.extensions_map, ".plist": "text/xml", ".ipa": "application/octet-stream"}
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()
' "$PORT" "$DIR" > "$(pwd)/dist/ota.log" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
sleep 0.5
"$TS" serve --bg --https=443 --set-path "$MOUNT" "http://127.0.0.1:$PORT" >/dev/null
echo "Serving $DIR (pid $(cat "$PIDFILE"))"
echo "Open on the iPhone: $BASE/"
