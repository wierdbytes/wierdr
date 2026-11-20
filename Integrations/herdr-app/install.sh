#!/bin/sh
# Installs Wierdr's layout for the Herdr desktop app into ~/.config/herdr-app (or
# $HERDR_APP_HOME): every mod in mods/ (wierdr-sidebar, wierdr-tabs, wierdr-pane), then
# layouts/wierdr.json with its preview wierdr.svg.
# Herdr reloads a mod on every saved file: the modules and icons go first, main.js last, so
# the reload that counts sees all of them; the layout goes after its mods.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
home="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
for src in "$here"/mods/*/; do
  src=${src%/}
  dest="$home/mods/$(basename "$src")"
  mkdir -p "$dest"
  (cd "$src" && find . -type f ! -name main.js) | while read -r f; do
    mkdir -p "$dest/$(dirname "$f")"
    cp "$src/$f" "$dest/$f"
  done
  cp "$src/main.js" "$dest/main.js"
  herdr-app check "$dest"
done
mkdir -p "$home/layouts"
cp "$here/layouts/wierdr.svg" "$home/layouts/wierdr.svg"
cp "$here/layouts/wierdr.json" "$home/layouts/wierdr.json"
echo "installed into $home: $(cd "$here/mods" && echo *), layouts/wierdr.json"
