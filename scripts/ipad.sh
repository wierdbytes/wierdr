#!/bin/bash
# Drive Wierdr on the physical iPad: screenshots, taps, typing, UI tree, orientation,
# install. Commands and notes: the header of scripts/device.sh.
#
#   scripts/ipad.sh start | status | shot [f] | tree | tap <label> | tap-xy <x> <y> | swipe …
#   scripts/ipad.sh type <text> | orient <…> | launch | kill | install [ipa] | stop
#
# Points: 1600x1200 in landscape. One-time on the iPad: Settings › Developer › Enable UI Automation.
DEVICE_KIND=ipad exec "$(dirname "$0")/device.sh" "$@"
