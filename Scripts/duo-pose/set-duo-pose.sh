#!/bin/bash
# Puts a booted iPhone Duo Simulator in a pose and checks that it took:
#
#   Scripts/duo-pose/set-duo-pose.sh <simulator UDID> <closed|open|book|tabletop>
#
# Xcode 27.1 can't fold the Simulator from the command line (simctl,
# devicectl and XCUIDevice have no pose), so this presses Device Hub's
# buttons through the Accessibility API (duo-pose-ax.swift, built on first
# use): Closed, Open, Partially Open for book, and Partially Open then
# Rotate Right for tabletop. ui-tests.yml runs it on GitHub's `xcode-27`
# image, whose bash is already trusted for Accessibility. On a Mac, the
# terminal running it needs Accessibility access (System Settings > Privacy
# & Security), and Device Hub must show the Duo: select it in the sidebar.
#
# The pose is checked from outside the app, through devicectl: the outer
# display active and upright for closed, the inner one upright (held wide)
# for open and book, and the inner one turned (held tall) for tabletop.
# Open and book look the same from there; the app tells them apart by the
# fold (`ActiveFold`). Exits 1 if the pose didn't take.
set -euo pipefail

usage() { echo "usage: $0 <simulator UDID> <closed|open|book|tabletop>" >&2; exit 2; }
[ $# -eq 2 ] || usage
udid=$1
pose=$2
case "$pose" in
  closed)   fold="Closed";         want_active=outer; want_held=portrait ;;
  open)     fold="Open";           want_active=inner; want_held=portrait ;;
  book)     fold="Partially Open"; want_active=inner; want_held=portrait ;;
  tabletop) fold="Partially Open"; want_active=inner; want_held=landscape ;;
  *) usage ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
hub="$(dirname "$(xcode-select -p)")/Applications/DeviceHub.app"
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/duo-pose.XXXXXX")
trap 'rm -rf "$work"' EXIT

helper="$work/duo-pose-ax"
xcrun swiftc -O "$here/duo-pose-ax.swift" -o "$helper"
if ! "$helper" trust | jq -e '.trusted' > /dev/null; then
  echo "::error::This process isn't trusted for Accessibility, so it can't press Device Hub's buttons." >&2
  exit 1
fi

name=$(xcrun simctl list devices -j | jq -r --arg u "$udid" '[.devices[][] | select(.udid == $u)] | first | .name // empty')
[ -n "$name" ] || { echo "::error::No simulator $udid." >&2; exit 1; }

# The active display ("outer", "inner" or "none") and how the phone is held
# ("portrait" or "landscape"), from devicectl. A display's own rotation
# follows the app on screen, so the device's orientation decides how it's
# held.
state() {
  xcrun devicectl device info displays -d "$udid" --json-output "$work/displays.json" -q > /dev/null
  xcrun devicectl device orientation get -d "$udid" --json-output "$work/orientation.json" -q > /dev/null
  active=$(jq -r '.result.displays as $d
    | if ([$d[] | select(.primary)] | first | .active) then "outer"
      elif ([$d[] | select((.primary | not) and (.type | tostring | contains("integrated")))] | first | .active) then "inner"
      else "none" end' "$work/displays.json")
  held=$(jq -r '(.result.deviceOrientationNonFlat // .result.deviceOrientation // "")
    | if startswith("landscape") then "landscape" elif . == "portrait" then "portrait" else "unknown" end' \
    "$work/orientation.json")
}

if ! pgrep -x DeviceHub > /dev/null; then open -a "$hub"; fi
pid=""
for _ in $(seq 1 60); do
  pid=$(pgrep -x DeviceHub | head -1 || true)
  [ -n "$pid" ] && break
  sleep 1
done
[ -n "$pid" ] || { echo "::error::Device Hub didn't start." >&2; exit 1; }

# Waits for Device Hub's window to show the Duo's pose buttons: it can take
# a while to show a newly booted simulator, first the window (the helper
# exits 5) and then the device in it (exits 1: a runner once matched the
# window with only its sidebar buttons drawn). Fails if they never show.
await_buttons() {
  for _ in $(seq 1 60); do
    code=0
    "$helper" buttons "$pid" "$udid" "$name" > "$work/buttons.json" || code=$?
    [ "$code" -eq 0 ] && return 0
    [ "$code" -ne 1 ] && [ "$code" -ne 5 ] && break
    open -a "$hub"
    sleep 2
  done
  echo "Device Hub's pose buttons for $name weren't found (exit $code):"
  cat "$work/buttons.json"
  return 1
}

press() {
  "$helper" press "$pid" "$udid" "$1" "$name" > "$work/press.json" \
    || { echo "::error::Pressing $1 in Device Hub failed." >&2; cat "$work/press.json" >&2; exit 1; }
  echo "Pressed: $1"
}

# Waits up to $1 seconds for the condition in $2 to hold.
wait_until() {
  local deadline=$((SECONDS + $1))
  state
  until eval "$2" || [ $SECONDS -ge $deadline ]; do sleep 1; state; done
}

rotate_until_held() {
  for _ in 1 2 3 4; do
    [ "$held" = "$1" ] && return
    local before=$held
    press "Rotate Right"
    wait_until 15 '[ "$held" != "$before" ]'
  done
}


# Presses the pose's buttons and checks it took. Fails if it didn't.
set_pose() {
  state
  echo "Before: $active display active, held $held"
  # Closing a turned phone: turn it upright first, while the inner display shows.
  if [ "$want_active" = outer ] && [ "$active" = inner ] && [ "$held" != portrait ]; then
    rotate_until_held portrait
  fi
  press "$fold"
  wait_until 30 '[ "$active" = "$want_active" ]'
  [ "$active" = "$want_active" ] && rotate_until_held "$want_held"
  sleep 2
  state
  echo "After: $active display active, held $held"
  [ "$active" = "$want_active" ] && [ "$held" = "$want_held" ]
}

# The simulator can stop following Device Hub: Device Hub draws the pose
# pressed while the phone keeps the display it had, or none at all (seen on
# a runner before anything was pressed, and once locally). Pressing again
# doesn't move it; rebooting the simulator does, and also gets Device Hub
# to draw a device whose buttons never showed.
if ! { await_buttons && set_pose; }; then
  echo "The pose didn't take; rebooting $name and trying again."
  xcrun devicectl device info displays -d "$udid" || true
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  # A newly booted Duo shows no display for a while, and ignores a pose
  # pressed until it does.
  wait_until 120 '[ "$active" != none ]'
  if ! await_buttons; then
    echo "::error::Device Hub's pose buttons for $name weren't found, even after a reboot." >&2
    exit 1
  fi
  if ! set_pose; then
    echo "::error::The iPhone Duo didn't take the $pose pose: $active display active, held $held (wanted $want_active, $want_held)." >&2
    xcrun devicectl device info displays -d "$udid" >&2 || true
    exit 1
  fi
fi
echo "The iPhone Duo is $pose."
