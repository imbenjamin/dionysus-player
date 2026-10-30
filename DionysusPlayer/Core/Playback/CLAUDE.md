# Playback and subtitles

Loaded when working in `DionysusPlayer/Core/Playback/` or
`DionysusPlayer/Features/Player/`. The root `CLAUDE.md` has the engine
abstraction (`PlaybackEngine`, change the protocol and both conformers) and
how playback negotiates with the server; the Apple TV player's host is in
`DionysusTV/CLAUDE.md`.

## The fold (iPhone Duo)

`PlayerView` and `PlayerControlsOverlay` each read the fold
(`onActiveFoldChange`) and lay out through `PlayerFoldLayout`: tabletop puts
the picture above the fold and the whole overlay, top row and logo included,
below it; book pose moves the transport and scrubber to the trailing page.
Each reads it on its outermost frame, after the padding it drives: reading it
from `topSection`'s position fed back into that padding and locked the main
thread when folding back from tabletop. The root `CLAUDE.md`, "iPhone Duo: the
fold", has the rest.

## Picture in Picture

PiP is wired for AetherEngine's native (AVPlayer) route only, which covers
HEVC/H.264, effectively all real content. `AetherPlaybackEngine` owns the
`AVPictureInPictureController`, built around `AetherEngine.nativePlayerLayer`
and rebuilt whenever `engine.$currentAVPlayer` re-emits, behind an
`NSObject` delegate proxy (`PictureInPictureDelegateProxy`):
`AetherPlaybackEngine` can't conform to the Objective-C delegate itself
without giving up its throwing `init()`. On PiP start and stop it calls
AetherEngine's `setNativeSubtitleRendering(_:)`, which hands the selected
subtitle track to AVKit as a native WebVTT rendition, since the app's own
`SubtitleOverlayView` isn't inside the captured layer. The software
(sample-buffer) route (AV1, VP9, interlaced, legacy sources) has no PiP: the
button is simply absent there, since `isPictureInPicturePossible` never turns
true without a controller.

## Now Playing

**`AetherPlaybackEngine` sets `engine.ownsVideoNowPlayingSession = true`
before `load()`**: the app draws its own transport rather than using
`AVPlayerViewController` (which gets Now Playing from AVKit, and must *not*
also opt in; see AetherEngine's doc comment), and without it the lock screen
and Control Center show nothing. Opting in makes the host wire the transport
commands: `AetherPlaybackEngine` registers play, pause and the 10s skips on
`engine.videoNowPlayingSession.remoteCommandCenter` (re-registered on the same
`$currentAVPlayer` signal PiP rebuilds on), and `PlayerViewModel.start()`
stages title and subtitle (`railTitle`/`railSubtitle`) with
`engine.setNowPlayingInfo(title:subtitle:artwork:)` at once, the artwork
following once `RemoteImageLoader` fetches it. (The Apple TV player is the
opposite case: it runs in an `AVPlayerViewController`, so its engine is made
with `ownsNowPlayingSession: false` and the same call stages the info as the
item's `externalMetadata` for AVKit instead; `NowPlayingMetadata`, and
`DionysusTV/CLAUDE.md`'s player section.)

**The software route publishes its own** (`engine.ownsSoftwareNowPlaying`,
set on both platforms since AetherEngine 7.48.0): it has no AVPlayer, so
neither the native session nor AVKit had anything to publish, and the lock
screen, Control Center and the Apple TV's iPhone card showed nothing for a
title on it. Which titles those are depends on the device: an iPhone 16 Pro
decodes AV1 and H.264 High 10 in hardware and plays them natively, where an
Apple TV 4K takes the software route for AV1; VC-1 is software everywhere, so
Ocean's Thirteen (LAN server) is the title to check it with (the lock
screen and Control Center card confirmed on an iPhone 16 Pro, 2026-10-30). The engine writes the shared
`MPNowPlayingInfoCenter` from the same staging (`setVideoNowPlayingInfo` over
`setExternalMetadata`) and serves play, pause, the 10s skips and scrubbing
from `MPRemoteCommandCenter.shared()` itself, so the app registers nothing
for it.

## Reporting a stop

**A stop is reported only after a start** (`PlayerViewModel.stop()`).
Jellyfin's `UserDataManager.UpdatePlayState` (10.11) writes a reported
position straight to the resume point, so closing the player while it was
still loading reported 0 and wiped it; omitting the position is worse, since
the server then marks the item played. `start()` also checks for cancellation
before playing, so a close during the resume seek can't play, or report a
start, after the stop it raced. While offline, `stop()` skips the report
altogether (`ConnectivityMonitor.shared.isOffline`): the request could only
time out, and every close control looked dead for 20 seconds.

## Audio offset

A global lip-sync offset (Profile → Playback) and a per-title override (the
player's Audio panel), −500…+500 ms in 10 ms steps, in `AudioOffsetStore`
(device-wide, not per user: it corrects the device's audio chain; on tvOS
that means the keychain every Apple TV user shares, since `UserDefaults` is
per user there) and applied
by `AudioOffsetController` (`viewModel.audioOffset`), which both players'
panels draw from. The load passes it as `audioDelaySeconds`, so the first
frame is in sync; a live change calls `setAudioDelay`.

- **Where it applies:** AetherEngine's `.loopback` and `.software` routes
  (`AetherPlaybackEngine.isAudioOffsetAvailable(on:)`), following
  `$videoRoute` through mid-session reroutes. `.none` is skipped
  (`audioOffsetAvailability(on:)`): the route reads it while a session is
  rebuilt, including by each offset change, and treating it as "unavailable"
  made the controls blink out and took focus off them. A change that settles
  while unavailable waits and applies when the route returns. **Not on a server transcode**:
  AVPlayer owns `.remoteBypass` and offers no audio delay (an `AVAudioMix`
  needs an `AVAssetTrack`, which HLS doesn't vend), Jellyfin's transcode
  request has no offset parameter, and AetherEngine sends only
  HEVC-in-MPEG-TS VOD through its own ingest (AE#268). The controls hide.
- **A title follows the global value until it's given its own.** The panel
  opens on This Title; All Titles edits the global value and drops the
  title's own; Reset to Global (This Title only) drops it too.
- **A change settles for 0.75 s before reaching the engine**
  (`settleDelay`): each one costs a session-preserving reload on `.loopback`
  (about 0.3 s of held picture), a seek on `.software`. It saves at once, and
  closing the panel applies what's waiting (`flush()`).
- **On iOS it's a page of its own under Audio** when the title has a choice of
  tracks (Benjamin, 2026-10-18), reached from an "Audio Offset" row below
  them; with one track it sits on the Audio page itself. `+`/`−` repeat
  while held (`.buttonRepeatBehavior`).
- **The software route runs slightly offset on an eARC chain** (Living Room,
  2026-10-18), the reason this exists; the upstream report waits on a
  measured value.

## Spatial Audio (TrueHD Atmos and DTS:X)

Apple platforms can't bitstream TrueHD or DTS-HD, so AetherEngine decodes
them and, in the app's bridge mode (the engine default, `.surroundCompat`),
re-encodes to Dolby Digital Plus: the height channels are lost. Two settings
(Profile → Spatial Audio, both off by default, per device like the audio
offset: `SpatialAudioStore`) render them instead into a speaker bed
(`LoadOptions.objectAudioRendering = .render(layout)`, since AetherEngine
7.50.0). The bed goes out as lossless 24-bit PCM, which tvOS wraps in Dolby
MAT for an Atmos receiver and iOS plays as Spatial Audio, and as lossy Apple
Positional Audio (APAC) where AirPlay is in the route at load: PCM reached
AirPlay as stereo. It needs the `TrueHDObjectAudio`/`DTSXObjectAudio` traits
(`Packages/AetherEngineWithObjectAudio`, root `CLAUDE.md`). Design:
`docs/superpowers/specs/2026-10-19-spatial-audio-resume-season-tiles-design.md`.

- **Replaced APAC rather than joining it** (Benjamin, 2026-10-30): APAC or
  PCM is how the bed travels, not something a viewer can choose well, and
  `.render` makes the one call that matters (AirPlay). PCM also drops the
  APAC encode, about a core, which on the A15 Apple TV was the half of the
  work behind #850. The cost is disk: 1.15 Mbit/s per bed channel (~13.8
  for 7.1.4) in the Read-Ahead Buffer's segments. If a sink misbehaves on
  PCM, the fallback is a hidden Advanced switch forcing `.apac`, not a third
  option.
- **An AirPlay change mid-session rebuilds the bed**
  (`AetherPlaybackEngine.observeAudioRoute()`): `.render` decides at load
  only, so picking a HomePod mid-film left PCM going to AirPlay. A route
  change that adds or drops an AirPlay port reloads in place, mounted
  playing or paused as it was (`spatialBedNeedsRebuild`). Not across an
  external-playback edge (the video AirPlayed to a TV): AetherEngine reloads
  the session itself there, which re-chooses the bed. Shipped untested on
  hardware (no AirPlay device to hand; Benjamin, 2026-10-30).
- **One rendering per session, for both formats.** `objectAudioRendering` is
  `.off` or `.render(layout)` and applies to TrueHD Atmos and DTS:X alike, so
  two toggles with their own layouts need the format known before load.
  `PlayerViewModel.start()` predicts the track (`SpatialAudioRules`: the
  remembered choice, else the default, swapped for a same-language
  Atmos/DTS:X track when rendering would be on for it, as the engine's own
  pick does), loads with that format's layout, and once the remembered track
  is applied rebuilds once if the playing track needs another
  (`setSpatialAudio`, `reloadAtCurrentPosition(applying:)`, before the resume
  seek). An audio switch to a track needing another rendering rebuilds the
  same way first; the switch itself then replays the loaded options.
- **The rendering's rebuild goes before the audio switch, never after.** The
  reload keeps the playing track by itself (`LoadOptions` has no public track
  override), and AetherEngine's `selectAudioTrack` is a rebuild of its own on
  a task: a reload started while it's pending cancels it and rebuilds on the
  old track. So `PlayerViewModel.selectAudioTrack` queues the switch behind
  the rebuild (two rebuilds for a switch that changes the rendering), and
  `stop()`/`start()` cancel one still queued. `FakePlaybackEngine.audioEvents`
  pins the order.
- **Engine track ids aren't `MediaStream.index`**: external streams shift
  Jellyfin's numbering. `PlayerViewModel.physicalIndex(of:in:)` and
  `audioStream(forEngineTrackID:in:)` translate, shared with the Atmos hint.
- **Where it can't apply, nothing is rendered or rebuilt**: a server
  transcode (AVPlayer never sees the track), offline (downloads are
  HEVC/MP4), and the engine's own refusals (non-48 kHz, DTS:X's object
  presentations, OS below 26), which keep the bridge with the audio intact.
  The software route renders too since AetherEngine 7.48.0, and its own
  track pick prefers Atmos/DTS:X as the prediction assumes. DTS:X renders into 7.1.4 and 9.1.6 only, so its picker offers
  nothing else. The settings are hidden below iOS 26 and where a trait isn't
  built in (`SpatialAudioSupport`).
- **Playback Stats shows the bed's form in the audio Decoder row**
  (AetherEngine's own label: "TRUEHD Atmos → PCM 7.1.4", "DTS:X → APAC
  9.1.6"), **and a "Spatial Audio" row while it plays**, from
  `LiveTelemetry.objectAudio` ("7.1.4 · 13 objects, 4 overhead"; DTS:X shows
  its height channels): the one in-app sign the route was taken. tvOS's
  engine loops a silent Atmos stream so soundbars light their indicator
  (`AtmosOutputActivator`), only while every output is HDMI since 7.45.0
  (AE#834: over AirPlay to a HomePod pair it silenced the programme after a
  pause); nothing to do in the app.
- **What a receiver shows** (the help page lists all three; Benjamin,
  2026-10-30): Dolby Atmos, Multichannel PCM or LPCM, never DTS:X. tvOS
  sends the bed as Dolby MAT, which some sinks show as Atmos on their own;
  AetherEngine's silent Atmos stream (above) lights the rest for TrueHD
  Atmos, and never runs for DTS:X, so a DTS:X film may show as multichannel
  PCM. Measured on the Living Room AVR (2026-10-30, PCM bed): Gravity
  (TrueHD Atmos) shows Dolby Atmos, Apollo 13 (DTS:X) shows "Multi In"
  (multichannel PCM). Under APAC both showed Atmos (2026-10-20).
- **The section's footer is one sentence, and the rest is a page of its
  own** (`SpatialAudioHelp`, Benjamin, 2026-10-23): iOS's footer ends in
  Learn More…, which opens a sheet; the Apple TV's section ends in an About
  Spatial Audio row, since focus never reaches a footer there. Nothing on it
  may call the feature beta: the section was headed "Spatial Audio (beta)"
  for a day, and App Review rejects a store build with a feature labelled
  beta (guideline 2.2; `SpatialAudioHelpTests` keeps it out).
- **Stalls on the A15 Apple TV were AetherEngine #850, fixed in 7.48.0.**
  The TrueHD decode and APAC encode ran the engine's segment producer at
  only ~1.2x real time, and its QoS retune dropped it to `.utility` at 16 s
  of lead, where it ran below real time, so a 4K remux stalled every few
  minutes. The pump now stays on `.userInitiated` once it measures below
  real time there (28 min of a 4K Atmos remux, no stalls, Living Room,
  2026-10-25), and the help page's "may pause to buffer" paragraph is gone.
  If stalls come back, the Read-Ahead Buffer can't help: the producer is the
  limit, not the network.

## Read-Ahead Buffer

**How far ahead a direct-play file is loaded is a setting** (Profile →
Playback → Advanced, both apps; `ReadAheadBufferStore`): 30 s to 10 min in
30 s steps, 5 min by default, read at each load and passed as
`LoadOptions.forwardBufferSegments` (the engine's segments are ~4 s, so 5 min
is 75). AetherEngine's own default, about 40 s, ran dry on a 4K remux over
powerline and Wi-Fi (Benjamin, 2026-10-21): a direct-play remux has one fixed
bitrate, so the buffer is its only cushion, where a streaming service drops
quality instead. Players for local libraries buffer in minutes (Infuse,
Kodi's raised caches); ExoPlayer's 50 s and AVPlayer's own are tuned for
adaptive streams. Segments are disk-backed (~750 MB for 5 min of 4K) and the
engine caps the window at a quarter of free space. It does nothing on a
server transcode (`nativeRemoteHLS`), where AVPlayer buffers against the
server itself. Playback Stats' "Buffered" KB is what lies ahead in the
engine's segment cache (`SessionCacheStatus.currentForwardBytes`, since
AetherEngine 7.45.0); before, it read `liveTelemetry.cachedBytes`, which
also counts the already-watched segments kept for seeking back. The seconds
figure is AVPlayer's own, only a few segments. **On the software route**
(AV1, VC-1 and the like on device; every direct-play session on the
Simulator) the seconds are the engine's packet cache ahead of the playhead
(`bufferedPosition − currentTime`), which fills to the Read-Ahead Buffer, and
there is no KB: the engine publishes only that cache's resident size, played
packets included. Until 2026-10-23 the row read N/A there, since
`bufferedPosition` once tracked the playhead on that route.

## After the app comes back from the background

**A paused title keeps its decode pipeline in the background**
(`engine.retainsVideoPipelineWhenBackgrounded`, AetherEngine 7.48.0, set on
both platforms; 2026-10-30), so coming back to it costs no rebuild. The
system may still invalidate the decoders while the app is suspended (the
software route rebuilds a lost VideoToolbox session itself; the native
route's recovery is AVPlayer's). A session playing as the app leaves, or resumed
from the lock screen while away, still gets the background teardown:
AetherEngine releases its decode pipeline after the grace window
(`backgroundTeardownGraceSeconds`), and reloading on return is the host's job
(`reloadAtCurrentPosition()`'s doc comment). The
player reloads on `didBecomeActive` (with a fallback inside `play()`), and
**mounts the rebuild paused** (`reloadAtCurrentPosition { $0.autoplay = false }`,
AetherEngine#460): pausing after an autoplaying reload wedged the native route
on a permanent spinner. A paused mount publishes no clock, so
`pausedRebuildAnchor` stands in for the engine's zeroed one until a real tick,
seek or load; without it the scrubber read 0:00 and the progress reporter
saved that as the resume point. Duration is bridged from `engine.$duration`'s
own publisher, since the clock's ticks stop while paused.

## Subtitles

Two renderers, split by codec. **ASS/SSA goes to libass**
(`ASSSubtitleRenderSession`, on the `swift-ass-renderer` package); everything
else (SubRip, WebVTT, teletext, PGS and other bitmaps) renders through
`SubtitleOverlayView`'s own SwiftUI path on the cues AetherEngine publishes.

- **`LoadOptions.preserveASSMarkup` is deliberately not set.** The app fetches
  the complete `.ass` script itself (Jellyfin extracts any stream, embedded
  ones included, at `JellyfinAPIClient.subtitleURL`; `DownloadManager` stores
  every non-bitmap track as a sidecar), so AetherEngine's cue path stays as it
  is for every track. The flag is unnecessary here, not dangerous: it is
  gated by codec on the embedded path too, in `EmbeddedSubtitleDecoder.init`,
  which narrows it once into a stored property (now `emitsRawASSLines`).
  Don't re-raise AetherEngine#587, which upstream refuted by measurement.
- **A whole script, loaded once, never `reloadTrack` per cue.**
  `swift-ass-renderer` exposes only whole-script load and reload, and
  `reloadTrack` frees the current track synchronously, so feeding it a growing
  script blinks the subtitle off on every rebuild. It reloads only on a
  geometry change (0.4–1.7ms for a 218KB script), without clearing the
  outgoing frame.
- **Engine track ids match nothing on the server**, so a selected track is
  mapped back by *ordinal*, two ways. A track AetherEngine demuxed pairs with
  its `MediaStream` among *embedded ASS* entries
  (`jellyfinStream(forTrack:engineTracks:mediaStreams:)`); a sidecar the app
  registered pairs with what it was built from, among *externals*
  (`registeredSidecar(forTrack:engineTracks:registered:)`, shared by the
  streaming and offline paths). Both sides must be filtered identically:
  counting the wrong tracks serves another track's script, which reads as a
  bad file. `ASSSubtitleMappingTests` pins both.
- **On a transcode, the container's text tracks must be registered as
  sidecars.** The server's HLS carries no rendition for them, so nothing
  demuxes them, and every embedded SubRip and ASS track vanished from the
  picker until `externalSubtitleStreams(from:isRemoteHLS:)` registered them.
  Jellyfin says which: asked with this app's `DeviceProfile` it answers
  `MediaStream.deliveryMethod == "External"` for exactly those (and `"Encode"`
  for bitmaps it burns in). That is **not** `isExternal`, which says where the
  stream lives (an embedded ASS track on a transcode is `isExternal: false`
  with `deliveryMethod: "External"`). The route gate matters as much: direct
  play reports the same `"External"` where the engine already lists the
  tracks, so registering there shows every track twice (both checked on
  10.11.11). AetherEngine supports sidecars on the `nativeRemoteHLS` bypass
  since 6.14.0.
- **A cold fetch can take over a minute.** Jellyfin extracts an embedded track
  on demand and caches it (70s for a 4K remux, 0.03s after), so the request
  carries its own 180s timeout (`URLSession`'s 60s default cut it off), and
  until the script lands the cue path renders the track unstyled.

### Timing on a transcode

**libass is timed off AVPlayer's own subtitle timing, not the raw playhead.**
On a transcode AVPlayer's item time runs *ahead of the picture* after a seek:
Jellyfin restarts the transcode at the keyframe before the requested segment,
and AVPlayer anchors its timeline to the first segment it loads (measured
0.8–8.3s on one film). It keeps that anchor across job restarts, so segment
timestamps can't recover it (tried). AVPlayer's timing of the WebVTT rendition
AetherEngine injects for the same track does know it, and since AetherEngine
7.15.2 (#616, filed and verified by this app) the engine measures the lead
and publishes `sourceTime` without it. **Don't add a host-side offset**: it
would subtract the lead twice. Three things remain the app's job:

- **The rendition must stay selected**, or the engine has nothing to measure;
  an app-owned `AVPlayerItemLegibleOutput` suppresses its drawing
  (`setNativeSubtitleCapture`). Two traps, both found on device: an output
  that starts suppressing while AVPlayer is drawing a line freezes that line
  on screen for good, so the rendition is deselected *before* the output
  attaches; and a (re)attached output re-delivers the line on screen as new.
- **The engine re-measures only when a line starts**, so between a seek
  landing and that line `sourceTime` still carries the previous lead (up to
  1.8s off on device). `ASSSeekHold` paints nothing in that window, gated on
  the engine's `clock.sourceTimeFollowsPicture` (7.16.0, added at this app's
  request). The engine re-assigns `false` at every jump, so the sink must not
  deduplicate it.
- **The hold gives up after 5s of playback**, since the flag only turns true
  on a line the WebVTT rendition carries, and libass may have others to draw.
  That time is summed from small item-time steps, so a pause never releases
  the hold and a seek never counts towards it.

Direct play and offline need none of this: there `sourceTime` is the source
PTS.

### ASS/SSA Subtitles

Profile → Playback → Advanced → ASS/SSA Subtitles (named "Subtitle Styling"
until 2026-10-30, renamed to stay clear of Subtitle Style), on by default
(`styledASSSubtitlesEnabledDefault`), is an escape hatch for a script whose
typesetting fights the phone. The one gate is
`PlayerViewModel.handleSubtitleTrackChange`'s `isStyledASSEnabled()`; off, an
ASS track renders like SubRip, unstyled. It's read at each track selection.
`isStyledASSEnabled` reads `object(forKey:)` before `bool(forKey:)`, which
reports `false` for a key never written and would ship the feature off for
everyone who never opened Settings.

### Subtitle Style

Profile → Playback → Subtitle Style (both platforms; Benjamin,
2026-10-30) picks how `SubtitleOverlayView` draws a **text** cue: **Match
System**, the default, or **Dionysus**, the app's own look
(`SubtitleTextStyle.dionysus`). System reads Settings › Accessibility ›
Subtitles & Captioning through AetherEngine's `SubtitleCaptionStyle` (7.48.0)
in `SystemCaptionStyle`, which also follows changes while a title plays.

- **A field the user left alone keeps the Dionysus look**, as AetherEngine
  documents for a host drawing its own overlay (a field is set only where it
  differs from the system's default). So someone who never opened that page
  sees no difference, which is why System is the default: it changes
  only what someone chose there on purpose.
- **The background restyles the Dionysus panel** (one rounded panel per cue,
  not the system's per-line strip), and the system's window is a second panel
  behind it. Edge styles are approximated with shadows. Text colour follows
  the system's precedence against a cue's own colour
  (`SubtitleTextStyle.runColor`); a cue's font is never read.
- **Not restyled**: bitmap subtitles, and styled ASS through libass, which
  keeps the author's typesetting. Native-route Picture in Picture draws its
  WebVTT rendition in AVKit, which follows the system style in either mode.

### Geometry

libass gets a frame from the picture's top edge to the bottom of the overlay,
with `ass_set_margins` describing the bar below the picture and
`ass_set_use_margins` on, the documented way to put subtitles in the
letterbox. Dialogue moves into the bar; `\pos` signs stay on the picture.

- **The drawable region is the picture intersected with the safe area**, its
  bottom raised for the transport. The overlay ignores the safe area to sit
  over full-bleed video, so nothing else keeps subtitles off the rounded
  corners and sensor housing (a screenshot can't show it; only the device
  can). The insets come from the window: a `GeometryReader` inside an
  `ignoresSafeArea` view reports zeroes (measured).
- **The margins are signed; in landscape the bottom one is negative**, which
  libass documents as a cropped picture: the picture fills the screen and the
  frame stops short of the chrome. Clamping to zero mapped every `\pos` sign
  into a too-short rectangle (a sign at y 20–34 against 29–49, 30% small).
  `ASSSubtitleGeometryTests` pins both orientations.
- **Landscape needs `ass_set_font_scale`.** libass scales a regular event to
  the smaller of the frame and the video area, a positioned one to the video
  area. In landscape the frame is the smaller, so dialogue rendered 7% small
  at rest and 28% with the controls up (measured by rendered width).
  `Geometry.fontScale` (`max(1, pictureHeight / frameHeight)`) restores
  dialogue, `\pos` and `\an8` and is exactly 1 in portrait. Positioned events
  are unaffected (measured). `ass_set_storage_size` is not this knob (aspect
  ratio and blur only).
- **No top margin.** `use_margins` relocates every *regular* event into the
  margins, top-aligned ones included, so a top margin sent an `\an8` sign
  into the bar above the picture (y 9–23 against a picture at 324). The cost
  is that a bare `\an5` centres in the frame and sits low; `\an8` is common in
  typesetting and a bare `\an5` rare (usually with `\pos`, which is exempt).
- **The bottom clearance is measured**: `PlayerControlsOverlay` publishes its
  chrome's top edge through `BottomChromeTopKey`, since the chrome's height
  varies (the chapter and format row comes and goes) and it respects the safe
  area while the overlay doesn't.

### Fonts

**Embedded fonts are registered with CoreText, not fontconfig.**
`engine.fontAttachments` (from AetherEngine's probe, whatever
`preserveASSMarkup` says) are written to a temp directory and registered with
`CTFontManagerRegisterFontsForURL` at `.process` scope; the fontconfig
provider would resolve embedded faces at the cost of every system one.
Teardown unregisters exactly what it registered.

**Two routes have nothing to probe and fetch the fonts instead**: a server
transcode (nothing local demuxes the source) and offline (MP4 has no
attachment streams). `MediaSourceInfo.mediaAttachments` lists them on every
route (checked on 10.11.11), so live playback fetches
`/Videos/{id}/{source}/Attachments/{index}` and `DownloadManager` stores them
as sidecars at enqueue. Build that URL from ids: `MediaAttachment.deliveryUrl`
is filled only when the request carried a `DeviceProfile`.

- **The engine's own attachments win whenever it has any**
  (`assFonts(engineAttachments:fetched:)`). Not a merge: on direct play both
  lists hold the same faces, and merging registers each twice.
- **Fonts never gate the script.** The script is applied the moment it lands
  and the fonts re-apply when they arrive (one extra parse on the fetching
  routes). `StyledSubtitleJourneyTests`' `.slowSubtitleFonts` journey pins it
  and failed against a build that waited.
- **Not every attachment is a font** (cover art is common).
  `JellyfinAPIClient.isFontAttachment` takes codec, MIME type or extension as
  sufficient, with WOFF the one veto, since `CTFontManager` can't register it.
- **Attachments are rare** (4 of 932 MKVs in the library this was built
  against), so all of this must cost nothing when there are none.
