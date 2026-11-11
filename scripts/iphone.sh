#!/bin/bash
# Drive Wierdr on the physical iPhone: screenshots, taps, typing, UI tree, orientation,
# install (also over the tailnet). Commands and notes: the header of scripts/device.sh.
#
#   scripts/iphone.sh start | status | shot [f] | tree | tap <label> | tap-xy <x> <y> | swipe …
#   scripts/iphone.sh type <text> | orient <…> | launch | kill | install [ipa] | stop
#
# Points: 428x926 in portrait (iPhone 13 Pro Max). WDA forward on localhost:8101 over USB.
# One-time on the iPhone: Settings › Developer › Enable UI Automation.
DEVICE_KIND=iphone exec "$(dirname "$0")/device.sh" "$@"
