# Night Mode: design

2026-11-16. Issue: #363 ("[Feature] Night / Sleep mode"; the PR closes it). Status: approved. Next: a feasibility check and
implementation plan (`docs/superpowers/plans/`).

## Intent

A way to watch late at night without waking the house, or with the screen
nearly dark: quieter, flatter audio and a dimmer picture, set once and switched
on and off in one tap or on a schedule. It lives in the player on iPhone, iPad
and Apple TV, with a schedule in Profile.

## Goals

- One **Night Mode** switch in the player that applies three saved settings:
  - **Night Audio**: dynamic-range compression (loud parts quieter, quiet
    parts louder), on or off.
  - **Volume Limit**: the app's audio output as a percentage of normal, 0 to
    100% in 5% steps.
  - **Brightness**: the picture's brightness, 0 to 100% in 5% steps, with
    one-tap shortcuts to 0% and 100%. It affects only the video and the
    subtitles; the controls, panels and overlays draw normally.
- **Remembered until turned off**: Night Mode and its three levels survive
  closing the player and relaunching the app.
- **A schedule** in Profile: optional automatic on and off times, each chosen
  with a time picker.
- Both platforms (iOS/iPadOS, tvOS), with the same behaviour.

## Non-goals

- A sleep timer (stop playback after N minutes or at the end of an episode).
  The name is "Night", not "Sleep", for that reason. A later feature can sit
  beside it.
- Capping the device's own volume. iOS and tvOS offer no API for it; the
  device's volume buttons keep working, over a quieter output.
- Volume Limit on audio passed through undecoded to a receiver (see
  "Volume Limit and passthrough").
- Dimming the screen itself (`UIScreen.brightness`) or the Picture in
  Picture window.
- Per-title or per-user Night settings.

## Anti-goals

- **Night Mode quietly doing nothing.** Wherever a setting can't apply to
  the stream playing, the panel says so on that row. A toggle that looks on
  and changes nothing is a failure.
- **A dark noon surprise.** Night Mode persisting means a film can start dim
  in daylight. Whenever Night Mode is on, the player shows it (see
  "Indicator"), so it's never mysterious.
- **Controls that dim with the picture.** At 0% the controls must still be
  fully readable and usable.

## Decided (Benjamin, 2026-11-16)

- Subtitles dim with the picture.
- Settings are remembered until turned off.
- A schedule in the app's settings (Profile), with a time picker each for on
  and off.
- **Structure: option 1**, one Night Mode switch over three saved levels
  (like Night Shift). The schedule flips the switch; the levels are
  untouched by it. Rejected: three independent settings that the schedule
  sets, which would lose the night levels each morning or need hidden
  "night values" that recreate option 1 invisibly.
- **Volume Limit: approach A**, the engine's output volume, with the row
  saying when it can't apply. Rejected: B, asking AetherEngine for a gain
  stage so the limit works on passthrough too, which would decode the audio
  (losing Atmos), cost a 0.3 s hitch per change and wait on an upstream
  release.
- **Volume Limit where the app can't tell it's working** (Benjamin,
  2026-11-16): keep it everywhere, with an always-visible note on the
  affected route, rather than drop it on tvOS or add an engine gain stage.
  See "Volume Limit and passthrough".

## Approaches

| Part | Chosen | Considered |
|---|---|---|
| Structure | One switch over three saved levels | Three independent settings set by the schedule |
| Night Audio | AetherEngine `setAudioShaping` with `AudioShaping.Compressor.night` | none viable: the engine's own preset is what exists, and audio is fixed in the engine, not the host |
| Volume Limit | `AetherEngine.volume` (0...1) | A gain stage in AetherEngine (approach B above) |
| Brightness | A black layer over video and subtitles, opacity 1 - brightness | A shader in the engine: doesn't exist, and riskier with HDR10 and Dolby Vision than compositing over them, which the subtitles and controls already do |

## Behaviour

### The Night Mode state

Stored per device and shared by every user on it, as the audio offset and
Spatial Audio are (`SpatialAudioStore`'s pattern: `UserDefaults` on iOS, the
shared keychain on tvOS):

| Key | Default |
|---|---|
| Night Mode on | off |
| Night Audio | on |
| Volume Limit | 100% |
| Brightness | 100% |
| Schedule enabled | off |
| Turn on at | 22:00 |
| Turn off at | 07:00 |
| Last schedule boundary applied | none |

Defaults are my call: the first switch-on compresses the audio and changes
nothing else until a level is set.

**One stored on/off value, always the one in force** (Night Shift's model; my
call after the builder check). The switch in the player and in Profile shows
it and sets it; the schedule sets it at each boundary. There is no separate
override:

- A manual flip lasts until the next scheduled boundary sets the value again
  (off inside the window holds until the next start; on outside it holds
  until the next end).
- Turning the schedule off keeps the current value; nothing changes the
  moment the toggle is touched. Turning it on (or editing a time) changes
  nothing until the next boundary passes.
- Boundaries are applied by a pure function of (schedule, last boundary
  applied, now): the most recent boundary since the last one applied wins,
  so a boundary that passed while the app wasn't running is applied at
  launch or foreground. Several missed boundaries collapse to the latest.
- A window may cross midnight (22:30 to 07:00). Equal start and end times
  mean the schedule never triggers; the Profile page says so, and that check
  is my call.
- A boundary that passes **during playback** takes effect at once. A
  controller schedules a wake at the next boundary, and re-evaluates on
  foreground and on time-zone or clock changes
  (`significantTimeChangeNotification`).

### Applying it in the player

When Night Mode is in force (or as a level changes while it is):

- **Night Audio on**: `setAudioShaping(AudioShaping(compressor: .night))`;
  off: `setAudioShaping(AudioShaping())`. It goes through the
  `PlaybackEngine` protocol, implemented by `AetherPlaybackEngine` and faked
  by `PreviewPlaybackEngine`. It's also passed at load, so a new session
  starts shaped rather than rebuilding after it starts.
- **Volume Limit**: `engine.volume = limit / 100`, replayed on every load.
  Off means 1.0.
- **Brightness**: the dimming layer's opacity is `1 - brightness / 100`. Off
  means 0.

When Night Mode is off, all three return to normal in one step.

### What each costs, and what the panel says

- **Night Audio decodes the audio on the device.** While it's on, Atmos,
  TrueHD and DTS passthrough to a receiver, and the Spatial Audio object
  render, are replaced by compressed PCM; it takes priority over the Spatial
  Audio setting (AetherEngine's rule). Beside the toggle, its note: "Limits
  dynamic range. Turns off Atmos and passthrough while on." Every toggle (and Night
  Mode switching it) holds the picture while the engine rebuilds (AetherEngine
  quotes about 0.3 s; measured 1–2 s on the Living Room Apple TV, judged
  acceptable by Benjamin, 2026-11-16)
  at the playhead.
- **Night Audio on a server transcode** (`.remoteBypass`, where AVPlayer owns
  the audio) can't apply: `audioShapingState` reads `.unavailable`, and the
  row says "Not available when transcoding". It still applies to the next
  stream that can.
- **Volume Limit and passthrough.** `engine.volume` scales audio the device
  mixes. Audio passed undecoded to a receiver (Apple TV over HDMI, an iPhone
  on an HDMI adapter) may not be scaled. AetherEngine has no state for "sent
  to a receiver untouched" (`audioDelivery`'s `.streamCopy` also covers audio
  the device decodes itself), so the app may not be able to tell. It may be
  moot: on the Living Room setup TrueHD and DTS reach the AVR as DD+ 5.1,
  which suggests tvOS mixes and re-encodes, in which case the volume applies
  before encoding. **Feasibility measures it on the Living Room Apple TV**
  (DV TV and Atmos/DTS:X AVR), and the TV's own speakers over HDMI:
  - Volume applies on every route: ship as designed, no note.
  - It doesn't apply somewhere, and the app can tell when: that row reads
    "Set on your receiver" on that route.
  - It doesn't apply somewhere, and the app can't tell: **Volume Limit stays
    on both platforms, with an always-visible note under the row on the
    route family affected** (on the Apple TV: "May not apply when audio goes
    to a receiver"). Benjamin, 2026-11-16: option 1 of three, over dropping
    it on tvOS or an engine gain stage. This is the one accepted exception
    to the "quietly doing nothing" anti-goal: the note keeps it from being
    quiet.
  With Night Audio on, the engine decodes to PCM, so no passthrough of the
  source remains.
  **Measured (Living Room, 2026-11-16, Release build): the first branch
  holds; no note ships.** The Apple TV decodes every format to multichannel
  PCM before HDMI (the AVR shows "Multi In" even for a stream-copied E-AC-3
  track), so `engine.volume` applies on every route seen: Nobody 2 DD+
  stream-copied (Night Audio off), Life of Brian (TrueHD), Gravity (TrueHD
  Atmos rendered to the PCM bed, AVR "Atmos"). Task 5b (the note) is dropped.
  Brightness dims Dolby Vision (Gravity) evenly. A Debug build stalls the
  Atmos render (~0.2x real time); device checks use a Release build.

### Brightness layer

- **iOS**: a black `Color` with the computed opacity in `PlayerView`'s ZStack,
  above `SubtitleOverlayView` and below `PlaybackStatsOverlay`,
  `PlayerControlsOverlay` and every overlay above them (Skip, Next Up, the
  version question, the Night panel). It covers the picture's frame
  (`foldLayout.videoHeight` on the Duo, so tabletop dims only the picture),
  ignores hit testing and is hidden from accessibility.
- **Apple TV**: the same, between the subtitle layer (`TVPlayerOverlay`,
  which draws subtitles in a layer of their own) and the transport and panel.
  The builder places it in the UIKit host.
- 0% is a black picture with sound: listening with the screen dark. Controls
  appear at full brightness as usual.
- Picture in Picture is not dimmed (the PiP window is the system's).
- It sits over HDR and Dolby Vision the same way the subtitles do; check on
  device that an HDR picture dims evenly (feasibility).

## Where it appears

### iOS player

A moon button in the player's top row (`moon` / `moon.fill` when on, the
on-state badge the rotation lock uses), opening a compact panel built like the
track picker (a hand-rolled overlay, not a `Menu` or popover, for the reasons
in `PlayerControlsOverlay`'s doc comment):

```
Night Mode                         [ ON ]
───────────────────────────────────────
Night Audio                        [ ON ]
  Limits dynamic range. Turns off Atmos and passthrough while on.
Volume Limit        [0%]  [–]  60%  [+]  [100%]
Brightness          [0%]  [–]  40%  [+]  [100%]
───────────────────────────────────────
Schedule: 22:00–07:00       (or "Off")
```

- The three levels can be changed whether Night Mode is on or off (to set up
  ahead); they show greyed while off and apply as soon as it's on. My call.
- **Both levels share one row layout on both apps: `[0%] [−] value [+] [100%]`**
  (Benjamin, 2026-11-16, option A of four after a mockup; rejected: a slider
  whose held arrow jumps to an end, Select toggling to 0%, and preset chips
  under each row). −/+ step 5%, clamped; holding −/+ repeats; a button that
  would do nothing (− at 0%, + and 100% at 100%) is dimmed. Under VoiceOver
  each row is one adjustable element (swipe up/down 5%) with 0% and 100% as
  named actions.
- The schedule line opens nothing in the player (a summary only); it's my
  call to keep schedule editing in Profile.

### Apple TV player

A **Night** tab in the player panel, after Subtitles (Info, Chapters, Audio,
Subtitles, Night), with four rows: Night Mode, Night Audio (its note beside
its name, so the rows fit the panel), Volume Limit and Brightness, each level
row being the shared `[0%] [−] value [+] [100%]` layout. Up/Down move between
rows; on a level row Left/Right move focus among 0%, −, + and 100% (the
value takes no focus) and Select presses, holding Select on −/+ repeating
as on the Audio Offset page. The builder fits it into
`TVPlayerInputModel+Panel`'s row model.

### Indicator

While Night Mode is in force, the moon button shows its filled on-state on
iOS. On the Apple TV the transport shows a small moon glyph beside the time
(my call; it's the one place visible without opening the panel). The Night
tab's title carries no moon: no other tab has an icon (Benjamin, 2026-11-16).

### Profile

A **Night Mode** row in the Playback section on both apps (iOS
`ProfileView`'s `playbackRows`; the Apple TV's `TVProfileView`), pushing a
page with:

- the Night Mode switch and the three levels (the same as the player's
  panel, so it can be set up away from a film);
- **Schedule** (toggle), then **Turn On** and **Turn Off** time pickers,
  shown while the schedule is on.

iOS uses `DatePicker(displayedComponents: .hourAndMinute)` in the default
compact style (Benjamin, 2026-11-16: fine as is). **tvOS has no time picker**
(neither `DatePicker` nor `UIDatePicker` exists there), so each time is an
inline stepper row, `Turn On   [−] 22:00 [+]`, the same control as the level
rows: − and + move it by **15 minutes**, wrap past midnight, and repeat while
Select is held (Benjamin, 2026-11-16, option A; rejected: four hour/minute
picker rows, a 96-row list of times, a custom two-column wheel). A time set
on another device is per device, so tvOS only ever sees its own 15-minute
values; one stored off the grid (not reachable today) steps to the next
quarter hour. 12/24-hour follows the device's locale on both.

A Profile deep link (`DeepLink.ProfilePage`, e.g. `profile/night-mode`)
follows `CLAUDE.md`'s rule that a new destination updates `TESTING.md`'s
table, with a parser test and a journey per platform.

## Constraints

- **Shared code**: the store, the schedule logic and the controller go in
  `Core/` (compiled by both apps). Nothing touches Downloads, so no
  `#if DOWNLOADS`. A shared view model change ships on both platforms.
- **The `PlaybackEngine` protocol changes in both conformers** (shaping and
  volume). `PreviewPlaybackEngine` records what it was given, so UI tests can
  assert it.
- **AetherEngine 7.66.0** (the pin) must have `setAudioShaping`,
  `audioShapingState` and `volume`. All three are in 7.54.0; confirm at the
  pinned tag (feasibility).
- `@VoiceOverEnabled`, not the environment value, for anything that changes
  under VoiceOver.
- Strings through the String Catalog, synced in the same PR.
- Privacy: no new identifier, permission or destination. `UserDefaults` is
  already declared in each target's manifest.

## Tests (the regression net)

- **Unit**: the boundary function (schedule off, a boundary passed or not,
  midnight crossing, equal times, a manual flip held until the next
  boundary, several missed boundaries collapsing to the latest, turning the
  schedule off keeping the value, DST and time-zone change); the store's defaults and clamping to 0...100 in steps of
  5; the controller's next-wake time; the player view model applying each
  setting to the engine at load and on change, and resetting on off.
- **UI journeys** (both platforms, against the fake engine): open the panel,
  turn Night Mode on, change each level, assert what the fake engine received
  and the dimming layer's opacity (an identifier on the layer, not the
  screen root); the Profile page's schedule; the deep link.
- **Accessibility audit** on the panel and the Profile page.
- **Device checks** (not automatable, recorded in the PR): HDR/DV dims
  evenly; Night Audio audibly compresses; Volume Limit on passthrough.

## Left to the builder

- Exact view-model and file names, and where the controller is owned
  (`AppState`, injected into the player view models).
- How a level change during the 0.3 s rebuild is handled (AetherEngine folds
  repeated shaping calls; check that toggling quickly doesn't stack rebuilds).
- Panel heights and animation in the iOS overlay; the Apple TV panel's focus
  path.
- Whether the panel's Night Audio and Spatial Audio notes share wording with
  the existing Spatial Audio help.
