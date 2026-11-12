#!/bin/sh
# Opens a `dionysus://` link (#406) on a Simulator, for debugging:
#
#   Scripts/deeplink.sh 'dionysus://play/<id>?t=1:02:03&stats=1'
#   Scripts/deeplink.sh 'dionysus://library/<id>?sort=dateAdded&order=desc' <udid>
#
# The device defaults to the booted one (`xcrun simctl openurl booted`); name
# one by UDID when more than one is booted. Quote the link: `&` and `?`
# mean something to the shell. A bare destination (`home`, `play/<id>`) gets
# the scheme added. The grammar is in CLAUDE.md, "Deep links", and the spec
# under docs/superpowers/specs/.
#
# Links navigate and play; none signs in or changes data. Physical devices
# aren't reached from here.
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 <dionysus:// link> [simulator udid]" >&2
    exit 64
fi

link=$1
case $link in
    dionysus://*) ;;
    *://*)
        echo "$0: not a dionysus:// link: $link" >&2
        exit 64
        ;;
    *) link="dionysus://$link" ;;
esac

device=${2:-booted}
if [ "$device" = booted ] && ! xcrun simctl list devices booted | grep -q Booted; then
    echo "$0: no Simulator is booted; boot one or pass its UDID" >&2
    exit 69
fi

xcrun simctl openurl "$device" "$link"
echo "Opened $link on $device"
