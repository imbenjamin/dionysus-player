# Audio offset (lip-sync correction)

Agreed with Benjamin on 2026-10-18. iOS and Apple TV.

## Goal

Let people correct audio/video sync for their own setup. A soundbar, AVR or
TV processing chain adds latency the app can't know, so the correction has to
be the viewer's. Two controls:

- **A global offset** in Profile → Playback, covering every playback where an
  offset can be applied.
- **A per-title offset** in the player's Audio panel, applied only to that
  title and overriding the global value.

Where an offset can't be applied, the controls are hidden.

**Why now.** On the Living Room Apple TV (Apple TV 4K 3rd gen, Apple TV → TV →
AVR over eARC, tvOS set to Dolby Vision + Atmos), every title on
AetherEngine's software route plays with a small constant offset (Ocean's
Thirteen, VC-1; The Celebrity Traitors: Uncloaked S2:E6, 1080i), while
native-route titles look right. It doesn't drift. A user control fixes
setup-specific error; the software route's own offset also goes upstream (see
"After it ships").

## Decisions (Benjamin)

| Question | Decision |
|---|---|
| What a per-title offset attaches to | The item itself: the movie, or the episode playing (never the series or the media source) |
| In-player scope | A toggle, **This Title** (default) or **All Titles** (edits the global value, mirroring Profile) |
| Untouched in-player value | The global value |
| Untouched global value | 0 ms |
| Reset | A **Reset to Global** button removes the title's own offset |
| Switching to All Titles when the title has its own offset | Clears the title's offset; the title follows the global value |
| Range and step | −500…+500 ms, 10 ms steps |
| Ownership | Per device, shared by every user on it, global and per-title alike |
| Placement | The player's Audio panel on both platforms; Profile → Playback on both |
| Server transcodes | Hidden (not possible today; see below) |

## What AetherEngine supports

`AetherEngine.setAudioDelay(_:)` / `LoadOptions.audioDelaySeconds` (AE#464):
seconds, positive delays audio, clamped to ±2 s, stored in the session's
options so it survives reloads, track switches and background returns.

| Route (`engine.videoRoute`) | Offset | Cost of a live change |
|---|---|---|
| `.loopback` (direct play, native) | Yes | Session-preserving reload, about 0.3 s of held picture |
| `.software` (AV1, VC-1, MPEG-2, interlaced, legacy) | Yes | A seek to the current position |
| `.remoteBypass` (server transcode) | No | AVPlayer owns the stream; the engine never sees timestamps |
| `.audio`, `.none` | No | Nothing to sync against / nothing loaded |

**Server transcodes, investigated (2026-10-18):**

- **AVFoundation** has no audio-delay control on `AVPlayerItem`. `AVAudioMix`
  and `MTAudioProcessingTap` bind to an `AVAssetTrack`, which an HLS-streamed
  asset doesn't vend. Delaying video instead would mean taking over frame
  presentation (`AVPlayerItemVideoOutput`), giving up Dolby Vision/HDR
  passthrough.
- **Jellyfin** has no audio-offset parameter: neither the transcode request
  (`BaseEncodingJobOptions`, `StreamingRequestDto`) nor FFmpeg argument
  building (`EncodingHelper`) has one (`master`, 2026-10-18).
- **AetherEngine** already has a seekable ingest for remote HLS VOD (AE#268),
  where the offset would apply, but routes only HEVC-in-MPEG-TS there.
  Jellyfin's transcodes for this app are fMP4, so they take `.remoteBypass`.

So transcodes are hidden for now. Routing fMP4 transcodes through the ingest
is an AetherEngine feature request, not part of this work.

## 1. Storage: `AudioOffsetStore`

New, `Core/Persistence/AudioOffsetStore.swift`, compiled for both apps.

- Device-local `UserDefaults`, never sent to the server. One key for the
  global value, one for a map of item id → offset. Whole milliseconds.
- **Not keyed by user**, unlike `TrackPreferenceStore`; the doc comment says
  why (the device's audio chain, not a person's preference).
- **Keyed by item id only**, so streaming and an iOS download share a title's
  offset, as track choices do.
- API: `globalOffsetMilliseconds` (get/set, default 0);
  `offset(forItem:) -> Int?`; `setOffset(_:forItem:)`;
  `removeOffset(forItem:)`.
- Every write clamps to −500…+500 and rounds to the nearest 10. The range
  and step live in one place (`AudioOffset.range`, `AudioOffset.step`) that
  the store, view model and both UIs read.
- No cap on entries: each is a few bytes, and only Reset clears one.
- tvOS keeps it in the keychain every Apple TV user shares
  (`KeychainStore.Scope.allUsers`), not `UserDefaults`: the app runs as the
  current Apple TV user, so its `UserDefaults` is per user. (Corrected after
  the final review, 2026-10-19; the first draft assumed it was device-wide.)

## 2. Engine

`PlaybackEngine` protocol, changed in both conformers (`AetherPlaybackEngine`,
`PreviewPlaybackEngine`):

- `load(...)` gains `audioOffset: TimeInterval`, passed as
  `LoadOptions.audioDelaySeconds` through `makeLoadOptions`, so the first
  frame plays in sync with no reload.
- `setAudioOffset(_ seconds: TimeInterval)` calls `setAudioDelay`.
- `isAudioOffsetAvailable: Bool` and
  `onAudioOffsetAvailabilityChange: ((Bool) -> Void)?`, derived from
  `engine.$videoRoute` through a pure function
  (`AudioOffsetAvailability.isAvailable(on: VideoRoute)`): true on
  `.loopback` and `.software`, false otherwise. Following the published route
  covers AetherEngine's own reroutes mid-session.
- `PreviewPlaybackEngine` records what it was given (load offset, last
  `setAudioOffset`) and reports availability per scenario; a new UI-test
  scenario, `audioOffsetUnavailable`, stands in for a transcode.

## 3. `PlayerViewModel`

The feature lives here; views only draw it.

**State:**

- `audioOffsetMilliseconds`: in effect for the playing item (its own offset,
  else the global).
- `audioOffsetScope`: `.thisTitle` | `.allTitles`.
- `hasTitleAudioOffset`: the item has its own offset (enables Reset).
- `isAudioOffsetAvailable`: from the engine; false hides every control.
- `canDecreaseAudioOffset` / `canIncreaseAudioOffset`: false at the ends.

**Actions:**

| Action | This Title | All Titles |
|---|---|---|
| `stepAudioOffset(by: ±1)` | Saves value ± 10 as the item's own offset (the first step creates it, from the global value) | Saves global ± 10 |
| `setAudioOffsetScope(_:)` to it | No write; the value is unchanged until the first step | Removes the item's offset; it follows the global |
| `resetAudioOffsetToGlobal()` | Removes the item's offset; scope stays This Title | Not offered |

**Applying:**

- A step saves at once and updates the displayed value at once. The engine
  gets the value after **0.75 s** without a further step, so a burst costs one
  re-sync. The delay runs on an injected clock, so tests never sleep.
- A pending value is applied at once when the panel closes, the player stops,
  or the item changes.
- A scope change or reset applies only if the effective value changed.
- The value is converted to seconds and clamped again before reaching the
  engine.

**Lifecycle:**

- The scope resets to This Title when the panel opens
  (`audioPanelDidOpen()`, called by both views) and when the item changes.
- `start()` / `startOffline()` and every item change (Next Up, the next
  playlist item) read the item's effective value from the store and pass it
  to `load`.
- The item id is the playing item's: for a show, the episode playing.

**VoiceOver:** a change announces the new value ("40 milliseconds, audio
later"); a step refused at a limit announces nothing.

**Display text** (one shared formatter, `AudioOffsetFormat`):

| Value | Visual | Hint | Spoken |
|---|---|---|---|
| 0 | `0 ms` | In sync | "0 milliseconds, in sync" |
| +40 | `+40 ms` | Audio later | "40 milliseconds, audio later" |
| −30 | `−30 ms` | Audio earlier | "30 milliseconds, audio earlier" |

Numbers use the locale's formatting; "ms", "milliseconds" and the hints are
localized.

## 4. Apple TV

**Player, Audio tab.** The track list is unchanged. When the offset is
available, an **Audio Offset** heading and three rows follow it in the same
scrolling list (the tab's content stays 330pt tall):

1. **Offset**: "Audio Offset", **‹ +40 ms ›**, and the hint line. Left/Right
   step; holding repeats about 10 a second. The chevrons dim at the ends.
   Select does nothing.
2. **Scope**: two capsules, **This Title | All Titles**; Left/Right or Select
   switches.
3. **Reset to Global**: Select resets. Dimmed, and skipped by focus, while
   the title has no offset of its own, so nothing moves.

- Down lands on the chosen track as today; Down from the last track goes into
  the offset rows, Up comes back.
- Hidden when unavailable. The Audio tab still shows for one track.
- A step counts as panel input, so the panel doesn't time out.
- `TVPlayerInputModel+Panel` stays pure: the context carries the offset state
  (available, can step each way, has own offset, scope), `contentCount` and
  focus rules cover the new rows, and three commands
  (`stepAudioOffset(Int)`, `setAudioOffsetScope(_)`, `resetAudioOffset`) run
  through `TVPlayerCommandRunner` to `PlayerViewModel`.

**Accessible transport:** the offset row is one adjustable element (swipe up
or down to step), "Audio Offset" with the spoken value; the scope row is a
button whose value is the scope; Reset is a button, not enabled while there's
nothing to reset.

**Profile → Playback:** a row **Audio Offset**, value `+40 ms`, opens a page
in the Next Episode Countdown style: a large value, the hint line, **−** and
**+** buttons (Select steps, holding repeats), and **Reset to 0 ms**, dimmed
at 0. The section footer adds: "Audio Offset delays or advances audio to
correct lip sync for your TV or receiver. Titles can override it from the
player's Audio panel."

## 5. iOS

**Player, tracks panel, Audio page:**

- The Audio page exists when there's a track choice **or** the offset is
  available. Track rows show only with a choice; the **Audio Offset**
  section shows whenever the offset is available.
- **Offset row**: label, value and hint, with **− / +** capsule buttons in the
  panel's dark style (hold repeats). Hand-built, not a system `Stepper`, whose
  light chrome would break the overlay the panel's doc comment explains.
- **Scope**: a two-segment control, This Title | All Titles, in the same style.
- **Reset to Global**: a button row, disabled and dimmed with no own offset.
- **Tracks button**: also enabled when only the offset is available, opening
  straight onto Audio (as it opens onto Subtitles when that's the only choice).
- **Root Audio row**: shown with a track choice or an offset; its value is the
  current track, or the offset when there's no track choice.
- `estimatedHeight(for: .audio)` adds the section's rows from `@ScaledMetric`
  heights.
- VoiceOver: the offset row is one adjustable element; the − / + buttons are
  hidden from it; the scope segments are selectable buttons.

**Profile → Playback** (`playbackRows`, shared by iPhone and iPad): an
**Audio Offset** row with its value and a system `Stepper` (10 ms,
−500…+500); a **Reset to 0 ms** button row beneath it while non-zero; the
footer adds the same sentence as tvOS.

## 6. Testing

**Unit** (shared, so both unit targets run them):

- `AudioOffsetStore`: default 0; clamp and round on every write; set, read and
  remove per item; independent of user.
- `PlayerViewModel`: effective value; steps under each scope; All Titles
  clears the own offset, This Title writes nothing; Reset; one engine call for
  a burst after 0.75 s (injected clock); flush on panel close, stop and item
  change; scope reset on panel open and item change; load carries the offset;
  unavailable hides; ends disable.
- `makeLoadOptions` sets `audioDelaySeconds`; `AudioOffsetAvailability` over
  every `VideoRoute`.
- `AudioOffsetFormat`: visual, hint and spoken text.
- tvOS reducer: Down from the last track, Left/Right steps, scope, focus
  skipping a dimmed Reset, commands, hidden when unavailable.

**UI journeys** (full plans, not smoke):

- iOS: on a one-track title, open the tracks panel, step, switch scope, reset;
  relaunch and find the title's value kept; `audioOffsetUnavailable` hides the
  section; Profile stepper and reset.
- tvOS: the same by remote (Down into the rows, Left/Right, scope, Reset),
  Profile's Audio Offset page, and the accessible transport's adjustable row.
- The accessibility audits cover the new rows and pages.

## 7. Documentation

- `Core/Playback/CLAUDE.md`: an "Audio offset" section: routes, why
  transcodes can't, the 0.75 s settle, per-device storage.
- `DionysusTV/CLAUDE.md`: the Audio tab's rows and focus rules.
- `TESTING.md` (the new scenario), `README.md` (features), the String Catalog.
- `PRIVACY.md`: no change (no permission, SDK or destination). Both privacy
  manifests already declare UserDefaults; confirm during implementation.

## After it ships (not in this work)

- With Benjamin's OK, a debug build on Living Room: dial Ocean's Thirteen into
  sync, check Inside Out 2 needs 0, and file an AetherEngine issue with the
  software route's offset as evidence for automatic compensation.
- AetherEngine feature request: route fMP4 HLS transcodes through the AE#268
  ingest so the offset applies to transcodes.
- AetherEngine issue: 1080i H.264 on the software route hands the layer about
  51.4 fps against a 50 Hz display, dropping the surplus.

## Out of scope

Automatic calibration, per-output values (HDMI vs AirPods), syncing offsets
across devices, and any change to how transcodes play.
