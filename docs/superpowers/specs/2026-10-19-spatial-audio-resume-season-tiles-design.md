# Spatial Audio for TrueHD Atmos and DTS:X, Resume after a rewatch, season tiles

Agreed with Benjamin on 2026-10-19. iOS and Apple TV. Three independent
parts, one plan, ahead of the 1.2.0 App Store submission.

## 1. Resume after a rewatch

**The bug** (Benjamin, 2026-10-14). Rewatching a title and stopping partway
leaves Jellyfin's `UserData` with `Played: true` and a
`PlaybackPositionTicks > 0`. Both platforms offer Resume only when the item
is *not* played, so the page shows Play and starts from the beginning.

The gates, all of which require `!isPlayed`:

- `MediaItem.isPartWatched` (`Core/Models/MediaItem.swift`), which iOS's
  `PlayResumeButtonRow` uses for its label, action and progress overlay.
- `TVDetailActions.hasResume` and `TVDetailFormat.playTitle` on tvOS.
- `DownloadedPlayResumeButtonRow` on iOS (`!item.isPlayed &&
  item.resumePositionTicks > 0`): in scope, so a title offers the same
  button streamed and downloaded (Claude's call).

**The fix.** An item with a saved position offers Resume (and, on tvOS, the
Restart button beside it) whatever its played state. "Saved position" means
`playbackPositionTicks > 0` on an item that has one (a movie, an episode, a
video); a Series or Season, which carries no position of its own, keeps
today's rule (`playedPercentage` between 0 and 1, not played). The Watched
toggle, the watched badge and Continue Watching are unchanged.

Before changing `isPartWatched` itself, the builder checks its other callers
(about 60 uses of `isPartWatched`/`isPlayed` across both apps): if some mean
"in progress for the badge" rather than "can resume", split the property
instead of changing its meaning. Unit tests cover played + position, played
without position, unplayed + position, and a Series.

## 2. Season tiles

**The bug.** A Season in a rail (Home on tvOS showed one: an American Horror
Story season) is captioned with the season's own name alone, and VoiceOver
reads "13, Button". `MediaItem.railTitle` returns `name` for anything but an
episode, and `railSubtitle` returns nil for a season.

**The fix**, in the shared model, so every rail on both platforms changes:

- Title: the show's name (`seriesName`), falling back to the season's name.
- Subtitle: the season's name as Jellyfin gives it ("Season 13",
  "Specials"); nil when the title already fell back to it.
- `accessibilityDescription` follows, so VoiceOver reads "American Horror
  Story, Season 13".

The grid's system posters (`TVPosterCollection`) read the same two
properties, so they follow. Check the iOS rail and the tvOS rail and grid by
screenshot.

## 3. Spatial Audio for TrueHD Atmos and DTS:X

### Why

On an AVR with height speakers, a TrueHD Atmos or DTS:X track plays without
its heights. Apple platforms can't bitstream TrueHD or DTS-HD, so
AetherEngine's audio bridge decodes the track and, in the app's current mode
(the engine default, `.surroundCompat`), re-encodes it to lossy Dolby Digital
Plus. On the Living Room AVR it arrives as DD+ 5.1. AetherEngine (7.40.0 and
later) can instead render the heights into a speaker layout and deliver Apple
Positional Audio (APAC): tvOS sends it to the receiver as Dolby MAT (Atmos),
iOS plays it as Spatial Audio (AirPods, built-in speakers). The trade is a
lossy encode in exchange for the heights, so it's the viewer's choice.

Reference: AetherEngine's `docs/formats.md`, "TrueHD Atmos with heights" and
"DTS:X with heights", and README › Optional components (at 7.42.0).

### Decisions (Benjamin)

| Question | Decision |
|---|---|
| What the setting chooses | On/off: today's behaviour, or Spatial Audio. No separate lossless (PCM) choice |
| How many settings | Two: one for Dolby Atmos (TrueHD), one for DTS:X |
| Layout | Each has its own layout picker, visible only while its toggle is on |
| Atmos layouts | 5.1.2, 5.1.4, 7.1.2, 7.1.4, 9.1.6 |
| DTS:X layouts | 7.1.4, 9.1.6 (the engine renders DTS:X into no others) |
| Default layout | 7.1.4 for both, on both platforms |
| iOS | Gets both settings; its 7.1.4 options read "7.1.4 (Recommended for AirPods)", or the footer says so if a row can't fit it |
| Patent licensing | Benjamin accepts shipping the decoders (see "Licensing") |

### Calls made in the design (Claude)

- **Both toggles default to off.** Spatial Audio only helps a setup with
  height speakers or headphones that render it, and costs a lossy encode
  everywhere else.
- **The settings are per device**, shared by every user on it, like the
  audio offset: they describe the hardware, not the person. On tvOS they
  live where the audio offset's global value does (the shared keychain);
  on iOS in `UserDefaults`.
- **Where they sit:** Profile → Playback on both platforms, as a group after
  Audio Offset. On tvOS, each toggle is an on/off row (Select flips it) and
  each layout a `TVSettingsPicker` page, as Next Episode Countdown is. On iOS,
  a `Toggle` and a `Picker` per format.
- **Playback Stats shows the object counts** while Spatial Audio plays, from
  the engine's `LiveTelemetry.objectAudio` (e.g. "7.1.4 · 13 objects, 4
  overhead"; DTS:X shows its bed and heights). It's the only in-app sign the
  route was taken. One row, in `PlaybackStatsReport`, so both platforms get it.
- **Labels.** Toggle titles "Dolby Atmos as Spatial Audio" and "DTS:X as
  Spatial Audio"; the layout row "Speaker Layout"; layout names stay plain
  ("7.1.4", formatted data, not translated). The footer says what it does and
  costs, roughly: "Keeps the height channels of TrueHD Atmos [DTS:X] tracks
  for a receiver with height speakers or for Spatial Audio headphones. The
  audio is re-encoded, so it isn't lossless." The builder may tighten the
  wording; it goes through the String Catalog.
- **Remembered track choices win.** With rendering on, the engine's automatic
  pick prefers a TrueHD Atmos or DTS:X track over others in the same
  language. The app's per-title track memory (local, keyed by item id) is
  applied as today and overrides that pick; the engine's preference only
  matters for a title with no remembered choice.

### Where it applies, and where it quietly doesn't

The engine falls back to today's path by itself, audio intact, whenever
rendering can't apply, and the app shows no error for it:

- a server transcode (Allow Transcoding chose to transcode: AVPlayer plays
  the server's stream, the engine never sees the track);
- the software route (the engine renders only on a VOD video session off the
  software path);
- TrueHD that isn't Atmos, DTS-HD MA that isn't DTS:X or is DTS:X in an
  alternate (object) presentation, anything not 48 kHz;
- an OS older than 26, where the APAC encoder doesn't exist.

Direct play already reaches the engine for these codecs: the device profile
lists `truehd` and `dts` (`DeviceProfile.swift`).

**Hidden where it can't work:** on iOS below 26 both settings are hidden
(the iOS floor is 18; tvOS's is 26). Each is also hidden if its engine
component isn't in the build (`AetherEngine.OptionalComponent.isBuiltIn`),
which guards a build that loses the trait by mistake.

### How it's wired

- **AetherEngine 7.42.0.** PR #360 (the weekly bump) already moves the pin
  from 7.35.1; land it first, or fold it in.
- **The two package traits, `TrueHDObjectAudio` and `DTSXObjectAudio`, must
  be on.** XcodeGen can't set traits (2.45.4 drops a `traits:` key silently).
  Use a small local package (e.g. `Packages/AetherEngineWithObjectAudio`)
  that depends on AetherEngine at the exact pinned version with both traits
  and re-exports it (`@_exported import AetherEngine`); `project.yml` depends
  on that package instead of AetherEngine directly. The alternative,
  patching the generated `.pbxproj` after each `xcodegen generate`, breaks
  whenever someone forgets. Consequences to handle:
  - The exact pin now lives in the local package's `Package.swift`, so
    `aetherengine-bump.yml` must bump it there, and root `CLAUDE.md`'s
    "Pinning AetherEngine" section must say where the pin is.
  - The Top Shelf extension links no AetherEngine and must stay that way.
  - LibDTSX arrives as a dynamic `DTSX.framework`, embedded in the app's
    `Frameworks/` beside FFmpeg's. The builder checks a local Release build
    of both targets embeds it, and the PR's "Release configuration
    compiles" check passes; it doesn't push tags. The real archive, manual
    signing and upload are proven by the next alpha tag, which Benjamin
    cuts (Claude's call).
- **The engine option is one for both formats.** At 7.42.0
  `LoadOptions.objectAudioRendering` is `.off` or `.apac(layout)`, and
  `.apac` applies to TrueHD Atmos and DTS:X alike, for the whole session. It
  also changes the engine's automatic track pick (it prefers an Atmos/DTS:X
  track in the same language). So two independent toggles with their own
  layouts need the app to know the format before it loads. **Approach
  (Benjamin, 2026-10-19: predict and reload, not an upstream per-format
  option):**
  1. **Predict the track before load.** From the media source's
     `MediaStream`s (`audioSpatialFormat`: `"DolbyAtmos"` / `"DTSX"`, with
     the codec, `truehd` / `dts`, to tell TrueHD Atmos from E-AC-3 JOC,
     which needs no rendering) and the title's remembered audio choice
     (`TrackPreferenceStore`, today applied only after load in
     `PlayerViewModel.applyStoredTrackSelection()`). With no remembered
     choice, predict the engine's own pick: the default track, or the
     Atmos/DTS:X track of the same language when rendering would be on.
  2. **Choose the option from the prediction:** the Atmos layout if the
     predicted track is TrueHD Atmos and the Atmos toggle is on; the DTS:X
     layout likewise; otherwise `.off`.
  3. **Correct after load.** Once the engine reports its tracks and the
     remembered choice is applied, if the playing track's format calls for
     a different option than the one loaded, rebuild once at the current
     position with the right option (`reloadAtCurrentPosition(applying:)`),
     before or right at the start of playback.
  4. **A track switch mid-film** to a track whose format calls for a
     different option (Atmos ↔ DTS:X with differing layouts, or to/from a
     format whose toggle is off) rebuilds the same way; a switch that needs
     no change of option stays the plain `selectAudioTrack`. Check first how
     7.42.0 treats a track switch under `.apac` (whether it renders the new
     track without a rebuild when the option already fits).
  Mis-predictions should be rare (Jellyfin's spatial labels and the
  remembered choice decide nearly every case), and the cost is one rebuild
  of a second or two. Per root `CLAUDE.md`, the protocol change goes into
  `PlaybackEngine` and both conformers, with `PreviewPlaybackEngine`
  recording the options it was loaded and reloaded with for UI tests. The
  prediction is a pure function, unit-tested over track lists.
- **When a setting changes mid-playback** it applies from the next title;
  the player doesn't rebuild the session for it. (A settings change can't
  happen mid-playback on tvOS, where Profile isn't reachable from the
  player, and on iOS the player is full screen.)
- **Atmos on the receiver.** On tvOS the engine itself loops a silent Atmos
  stream while APAC plays (`AtmosOutputActivator`) so soundbars that need it
  show Atmos; nothing to do in the app.

### Licensing and notices

- **Patents.** AetherEngine's 7.39.0 notes: the object-audio components "may
  be subject to third-party patent licensing; integrators who enable them are
  responsible for their own licensing." Benjamin accepted this on
  2026-10-19. The app already ships FFmpeg's TrueHD and DTS decoders, so the
  exposure is of the same kind.
- **`THIRD-PARTY-NOTICES`** gains LibTrueHD (MIT; truehdd's `truehd`/`oamd`
  crates under Apache-2.0 with LibTrueHD's `NOTICE`) and LibDTSX (LGPL-3.0-or-
  later as built, from harletty-bridge's `dca` port of FFmpeg's decoder;
  LibDTSX's `NOTICE` and `LICENSES/`), each under its own `# <name>` line,
  with versions; `LicenseDocumentTests` lists them. Update AetherEngine's and
  FFmpeg's versions there too if the bump changed them.
- **LGPL relinking.** `DTSX.framework` stays a separate, replaceable dynamic
  framework, as the FFmpeg frameworks do; don't statically fold it in.
- **Privacy.** No new data, permission or network destination, so
  `PRIVACY.md` and the privacy manifests don't change.

### Verification

- **Unit:** settings stores (defaults, persistence, visibility rules incl.
  iOS < 26 and `isBuiltIn`), `makeLoadOptions` (layout per format, off →
  no rendering, DTS:X never given a layout it refuses), the stats row text.
- **UI journeys, both platforms:** each toggle shows and hides its layout
  row; the layout picker lists the right options with 7.1.4 chosen (and the
  AirPods note on iOS); the choice survives relaunch. Under the harness the
  fake engine records the options the player loaded with.
- **Accessibility audit** over the new rows and picker pages.
- **Device, owed to Benjamin (ask before each deploy):** on Living Room
  (Atmos/DTS:X AVR), a TrueHD Atmos title and a DTS:X title each with the
  toggle off (DD+, as today) and on (the AVR shows Atmos; heights audible;
  Playback Stats shows the object counts), plus a seek and a resume. On iOS,
  the same titles on AirPods with Spatial Audio. `living-room-apple-tv-test-
  assets` in memory lists candidate titles.

### Documentation to update

- `DionysusPlayer/Core/Playback/CLAUDE.md`: the two settings, where the
  layout is chosen, the fallbacks.
- `DionysusTV/CLAUDE.md`: "HDR and audio" (TrueHD Atmos no longer always
  loses its heights) and the Profile rows.
- Root `CLAUDE.md`: where the AetherEngine pin lives now, and the traits.
- `README.md` if its feature list mentions audio formats.

## Out of scope

- A lossless PCM (`.lossless` bridge) choice. Considered and declined
  (Benjamin): the setting is today's behaviour or Spatial Audio.
- Detecting the speaker layout automatically. Not possible: with tvOS's
  Continuous Audio Connection on, every HDMI route reports 32 channels.
- Rendering DTS:X onto layouts other than 7.1.4/9.1.6, or sending 7.1.4 to a
  smaller system for the AVR to fold. Untested; revisit only after a device
  check.
- Per-title or per-user Spatial Audio choices.
