#!/bin/sh
# The landing's images (public/img) from full-size screenshots in shots/ (not in git: taken in the
# Simulator on the demo, docs/site.md) and the app icon. Needs cwebp (brew install webp).
set -e
cd "$(dirname "$0")"
s=shots; o=public/img
mkdir -p "$o"
phone() { cwebp -quiet -q 82 -resize 860 0 "$s/$1" -o "$o/$2.webp"; }
phone iphone-list.png iphone-list      # the hero's front phone: the wierdr space
phone iphone-banner.png iphone-banner  # the hero's back phone: a Done banner over a terminal
phone iphone-hosts.png iphone-hosts    # "Every agent. One list.": two machines
phone iphone-pane.png iphone-pane      # a permission prompt with the key panel
phone iphone-lock.png iphone-lock      # the Live Activity on the Lock Screen (og/uncarrier.mjs)
cwebp -quiet -q 80 -resize 2000 0 "$s/ipad.png" -o "$o/ipad.webp"
cwebp -quiet -q 80 -resize 1100 0 "$s/ipad.png" -o "$o/ipad-1100.webp"
icon=../App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
cwebp -quiet -q 90 -resize 256 0 "$icon" -o "$o/icon-256.webp"
sips -s format png -Z 180 "$icon" --out public/apple-touch-icon.png >/dev/null
ls -la "$o"
