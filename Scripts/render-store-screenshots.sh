#!/bin/sh
# Renders App Store screenshot sets (iPhone 6.9", iPhone 6.5", iPad 13")
# from a folder of raw device screenshots, using Scripts/store-screenshots/
# {gen.py,shot.swift}.
#
# This script does NOT capture the raw screenshots — that part is a manual
# Simulator/idb pass (see README.md's "Store screenshots" section for the
# checklist: dark AND light appearance, status bar overrides, which screens
# to capture, landscape handling for the player). This script only takes
# already-captured screens and turns them into the branded, framed,
# store-spec PNGs.
#
# usage: Scripts/render-store-screenshots.sh <raw-dir> <out-dir>
#
#   <raw-dir> must contain an iphone/ and an ipad/ subfolder, each holding
#   the slide source screenshots named to match Scripts/store-screenshots/
#   gen.py's SLIDES list (01-home.png, 02-grid.png, 03-detail.png,
#   04-player.png, 05-downloads.png, 06-light.png as of this writing — the
#   iPad and iPhone frames of a given slide are independent captures, since
#   the app looks different at each size, but should show the same content
#   so the sets read as one series).
#
#   <out-dir> is created if missing, with one subfolder per store size —
#   this is what you upload to App Store Connect, one subfolder per slot.
#
# example:
#   Scripts/render-store-screenshots.sh /tmp/raw-screens store-screenshots

set -e

RAW="$1"
OUT="$2"
if [ -z "$RAW" ] || [ -z "$OUT" ]; then
    echo "usage: $0 <raw-dir> <out-dir>" >&2
    exit 2
fi
if [ ! -d "$RAW/iphone" ] || [ ! -d "$RAW/ipad" ]; then
    echo "error: $RAW must contain iphone/ and ipad/ subfolders" >&2
    exit 2
fi

TOOLDIR="$(cd "$(dirname "$0")/store-screenshots" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build the snapshot tool once (cached in the work dir for this run — it's
# a few hundred milliseconds to compile, not worth checking in a binary).
SHOT="$WORK/shot"
swiftc -O -o "$SHOT" "$TOOLDIR/shot.swift"

mkdir -p "$OUT/appstore-iphone-69" "$OUT/appstore-iphone-65" "$OUT/appstore-ipad-13"

render_set() {
    kind="$1" src="$2" W="$3" H="$4" dest="$5"
    work="$WORK/$dest"
    mkdir -p "$work"
    cp "$src"/*.png "$work/" 2>/dev/null || true
    n_slides=$(python3 "$TOOLDIR/gen.py" "$kind" "$W" "$H" "$work" all | wc -l | tr -d ' ')
    idx=1
    while [ "$idx" -le "$n_slides" ]; do
        n=$(printf '%02d' "$idx")
        "$SHOT" "$work/slide$idx.html" "$OUT/$dest/$n.png" "$W" "$H"
        idx=$((idx + 1))
    done
}

render_set iphone "$RAW/iphone" 1320 2868 appstore-iphone-69
render_set iphone "$RAW/iphone" 1284 2778 appstore-iphone-65
render_set ipad   "$RAW/ipad"   2064 2752 appstore-ipad-13

echo "Rendered to $OUT:"
for f in "$OUT"/*/*.png; do
    dims=$(sips -g pixelWidth -g pixelHeight "$f" | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/ /;s/pixelHeight:/x/')
    printf '  %s  %s\n' "$dims" "${f#"$OUT"/}"
done
