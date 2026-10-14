# Playback and subtitles

Loaded when working in `DionysusPlayer/Core/Playback/` or
`DionysusPlayer/Features/Player/`. The root `CLAUDE.md` has the engine
abstraction (`PlaybackEngine`, change the protocol and both conformers) and
how playback negotiates with the server; the Apple TV player's host is in
`DionysusTV/CLAUDE.md`.

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

## After the app comes back from the background

AetherEngine releases a paused session's decode pipeline after its
background grace window (`backgroundTeardownGraceSeconds`), and reloading on
return is the host's job (`reloadAtCurrentPosition()`'s doc comment). The
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

### Subtitle Styling

Profile → Playback → Advanced → Subtitle Styling, on by default
(`styledASSSubtitlesEnabledDefault`), is an escape hatch for a script whose
typesetting fights the phone. The one gate is
`PlayerViewModel.handleSubtitleTrackChange`'s `isStyledASSEnabled()`; off, an
ASS track renders like SubRip, unstyled. It's read at each track selection.
`isStyledASSEnabled` reads `object(forKey:)` before `bool(forKey:)`, which
reports `false` for a key never written and would ship the feature off for
everyone who never opened Settings.

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
