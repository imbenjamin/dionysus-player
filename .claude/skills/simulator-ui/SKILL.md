---
name: simulator-ui
description: Drive real tap/type/scroll interactions in the iOS Simulator for Dionysus Player (login flows, navigating to a screen, exercising a button/gesture) — not just build/install/launch-and-screenshot. Use whenever a change needs manual verification that goes beyond "does it render": multi-step flows, confirming a binding/gesture actually works, or reaching a screen with no other route in. Also covers the pixel-measurement technique that makes clicks land reliably.
---

Synthesized `osascript`/System Events clicks land as real touches inside
the Simulator, including inside our own SwiftUI views (not just the Home
Screen) — confirmed working end-to-end 2026-08-12 (a full sign-in →
browse → play → scrub → toggle → close flow, all via this technique, no
misses once coordinates were measured correctly). The **entire failure
mode in past sessions was bad coordinates, not a permissions or hit-testing
problem** — see Gotchas.

## Prerequisites (one-time, per machine)

Accessibility + Automation permissions granted to whichever app is at the
root of the process tree running these commands (check with
`ps -o ppid= -p $$` walked up to the actual terminal/IDE app — Terminal.app,
not the shell) — System Settings → Privacy & Security → **Accessibility**,
and → **Automation** → (that app) → **System Events**, both checked. A
grant to an *already-running* app doesn't take effect until that app is
quit and reopened — toggling the checkbox off/on is not enough. There's no
CLI/`sudo` way around this; a human has to click Allow and, if needed,
restart the terminal app. If you hit `-25211` (assistive access denied)
after previously working, this is almost certainly why — see
Troubleshooting.

## Step 0 — reuse the booted Simulator, don't relaunch it

```bash
xcrun simctl list devices | grep -i booted
```

If one's already booted, target that device ID for everything below
instead of booting a fresh one. **Don't `simctl shutdown` or quit
Simulator.app when you're done** — leave it running so the next pass
(this session or a future one) can reuse it.

## Step 1 — build, install, launch

```bash
xcodegen generate   # only if project.yml or the source file set changed
xcodebuild -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

APP=$(find ~/Library/Developer/Xcode/DerivedData/DionysusPlayer-*/Build/Products/Debug-iphonesimulator \
  -maxdepth 1 -name "*.app")
xcrun simctl install <device-id> "$APP"
xcrun simctl launch <device-id> com.imbenjamin.dionysusplayer.ios
```

## Step 2 — map the window to screen coordinates

`click at {x,y}` takes **macOS screen coordinates**, not device pixels, and
Simulator only exposes one opaque `AXGroup` for the whole screen content
(no per-element accessibility tree) — so every click needs converting
through that group's frame:

```bash
# Window frame (includes title bar/toolbar chrome — not the device origin)
osascript -e 'tell application "System Events" to tell process "Simulator" to return {position of window 1, size of window 1}'

# The screen-content AXGroup specifically — look for the AXGroup entry
osascript -e 'tell application "System Events" to tell process "Simulator" to tell window 1 to return {role of UI elements, position of UI elements, size of UI elements}'
```

That second call returns parallel lists (roles, then positions, then
sizes) — find the `AXGroup` entry's position/size; that's
`{groupX, groupY, groupW, groupH}`. Re-run this if you're not sure it's
gone stale (it hasn't been observed to move across screens in practice,
but it's cheap to confirm).

## Step 3 — screenshot, then *measure*, don't eyeball

```bash
xcrun simctl io <device-id> screenshot /path/to/shot.png
```

Read it to see what's on screen — but **never eyeball the Read tool's
resized preview for click coordinates**. The preview is scaled down for
display (e.g. "1206×2622 shown at 920×2000") and a fraction-off guess
against it misses real controls by hundreds of native pixels — confirmed
directly: a Sign In button's true native center was at y-fraction 0.877,
versus ~0.62 read off the resized preview, a miss large enough to land the
click on nothing at all with zero visible effect (looks exactly like a
dead/ignored tap, easy to misdiagnose as a permissions or SwiftUI
hit-testing problem instead of a coordinate bug).

Instead, measure the real PNG:

```bash
python3 .claude/skills/simulator-ui/pixel_bbox.py /path/to/shot.png <x0> <y0> <x1> <y1>
```

Pick `<x0> <y0> <x1> <y1>` as a loose region around the element (rough
eyeballing is fine *here* — you're only bracketing a search area, not
pinpointing a click). The script finds whatever isn't background inside
that box and prints its bounding box + center in native screenshot pixels.
Works for a colored button fill, a white icon on black, a poster's edge
against a white card background — anything with contrast against what's
behind it. Pass `--bg r,g,b` if the region's own corner pixel isn't a
reliable background sample, `--tol N` to loosen/tighten the match.

## Step 4 — convert to screen coordinates and click

```
screenX = groupX + (px / deviceWidth)  * groupW
screenY = groupY + (py / deviceHeight) * groupH
```

`px,py` = the center from Step 3 (native screenshot pixels — the
screenshot's own `img.size` is `deviceWidth × deviceHeight`, e.g.
1206×2622 for an iPhone 17). Then:

```bash
osascript -e '
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    click at {screenX, screenY}
end tell'
```

**Check what `click at` returns.** It prints the AX element it actually
hit. A real control reads like
`button 1 of group 1 of ... of window "iPhone 17 – iOS 26.5" of application process Simulator`.
A miss reads as a bare, shallow `group ... of window ...` with no
`button`/similar in it — that's your signal the coordinates were off,
*before* you even take the follow-up screenshot.

Typing into a focused field is a plain `keystroke`:

```bash
osascript -e '
tell application "Simulator" to activate
delay 0.3
tell application "System Events" to keystroke "some text"'
```

Hardware buttons (Home, etc.) go through Simulator's own shortcuts, not a
screen tap — e.g. Home is `Cmd+Shift+H`:

```bash
osascript -e 'tell application "Simulator" to activate
delay 0.3
tell application "System Events" to keystroke "h" using {command down, shift down}'
```

## Step 5 — screenshot after *every* step, don't chain blind

Take a screenshot, look at it, *then* plan the next click — multi-step
flows compound coordinate errors and a keyboard/sheet/animation can shift
what's on screen between steps. If a tap seems to do nothing, re-measure
with Step 3 before suspecting anything else (see Gotchas).

## Verifying against the real server, not just visually

For flows this app drives against a real Jellyfin server (sign-in,
playback, resume position), a screenshot alone doesn't prove the
server-side effect landed. Cross-check with a direct API call instead of
guessing from pixels — e.g. confirming a reported playback position:

```bash
TOKEN=... ; USER=...   # from POST /Users/AuthenticateByName
curl -s "http://<server>/Users/$USER/Items?searchTerm=<title>&Recursive=true&Fields=UserData" \
  -H "X-Emby-Token: $TOKEN" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d["Items"]:
    ud = i.get("UserData",{})
    print(i["Name"], ud.get("PlaybackPositionTicks"), ud.get("PlayedPercentage"))'
```

This is how the Player controls-overlay rework (2026-08-12) was confirmed
to actually save a resume point on close, not just render correctly.

## Reading the app's own logs (also doubles as a click sanity-check)

```bash
xcrun simctl spawn <device-id> log show --start "<time>" --end "<time>" \
  --predicate 'processImagePath contains "Dionysus"'
```

A real tap generates a burst of UIKit event-dispatch log lines
(`EventDispatch`, `KeyboardUI`, etc.) around that timestamp. **A window
with zero matching log lines is confirmation the click never reached the
app at all** — used directly to diagnose a missed Sign In tap before the
pixel-measurement fix above was applied.

`simctl launch --console <device-id> <bundle-id>` (backgrounded, or via
the Bash tool's `run_in_background`) pipes stdout/stderr straight back for
a temporary runtime probe. Use `FileHandle.standardError.write(...)`
instead of `print()` for temp debug output — plain `print()` can sit in a
stdio buffer and never appear when stdout isn't a TTY.

## When taps genuinely can't reach the target state

For a screen many navigations deep, or gated behind a specific data shape
(e.g. a preloaded partial DTO), it's often faster to add a short-lived
debug hook instead of chaining a dozen taps: an env-var-gated `.task` on
the relevant `NavigationStack`'s `path` binding, reading
`ProcessInfo.processInfo.environment[...]`, set via
`SIMCTL_CHILD_<VARNAME>=value` *before* `simctl launch` (`simctl launch`
has no `-e` flag — the `SIMCTL_CHILD_` prefix is what actually reaches the
child process's env). Revert the whole hook (state var, `.task` block,
debug prints) before committing — `git diff --stat` against just the
intended files confirms nothing temporary leaked through.

## Gotchas

- **The single biggest failure mode is a bad coordinate, not a broken
  tool.** A miss looks identical to "the tap did nothing" whether it's a
  permissions problem, a SwiftUI hit-testing bug, or (by far the most
  common cause) just wrong math. Always re-measure via `pixel_bbox.py`
  against the real screenshot file before concluding anything else is
  wrong.
- **`-25211` ("osascript is not allowed assistive access")** can appear
  mid-session even after earlier clicks worked, and read-only AX queries
  (`UI elements enabled`, window position/size) keep succeeding right
  through it — that split is *not* a useful diagnostic on its own. Root
  cause found previously: a pending "Quit & Reopen" dialog for the
  terminal app that a permissions grant was silently waiting on. Fix is
  an actual quit-and-reopen of the terminal app, not toggling the
  Accessibility checkbox.
- **No on-screen software keyboard for `keystroke`-typed text** — the
  Simulator treats a connected hardware keyboard as the input source when
  driven this way, so don't expect (or wait for) a keyboard graphic in
  screenshots after typing; the text still lands in the focused field.
- **Rotation isn't scriptable** — `simctl` has no orientation control;
  that's a Simulator.app menu action only. A screenshot always comes back
  in the device's native portrait framebuffer regardless of the app's
  current orientation.
