# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dionysus Player is a native iOS/iPadOS client for Jellyfin media servers (tvOS/macOS
planned later). It talks to a Jellyfin server over the plain REST/JSON API
(https://api.jellyfin.org/) and plays media via AetherEngine, a third-party
FFmpeg + VideoToolbox playback engine (HDR10/HDR10+/Dolby Vision support), pulled
in as a Swift Package.

**Status: builds clean, playback verified on a physical device.** This was
originally scaffolded without a macOS/Xcode toolchain and expected to need
fixes in `AetherPlaybackEngine.swift`, but as of 2026-08-07 (Xcode 26.5, iOS
26.5 Simulator) `xcodebuild build` for the `DionysusPlayer` scheme succeeds
end-to-end — package resolution (AetherEngine + its FFmpegBuild/SMBClient/
LibDovi dependencies), compilation, and linking all complete with no errors,
and the `DionysusPlayerTests` suite (see `TESTING.md`) passes.
As of 2026-08-12, real playback on a physical device (iPhone 17,1, iOS 26.6)
was confirmed via the "stats for nerds" overlay: Dolby Vision (Profile 8)
source decoded in hardware through VideoToolbox HEVC, EAC3 audio
stream-copied to a 7.1 output, and buffered-duration/size stats updating
live. That covers direct-play HDR video + passthrough audio on one device;
still treat other paths (transcoding, non-Dolby-Vision HDR formats, other
devices, seeking/scrubbing edge cases) as unverified until separately
checked.

**v1.0.0** was tagged from `stable` and submitted for Apple App Review on
2026-09-07 — the app's first final (non-alpha/beta) release. See
`VERSIONING.md` for the tag/promotion mechanics.

**The deployment floor is iOS 18**, raised from 17 on 2026-09-23 to move
AetherEngine from 6.x to 7.x — 7.0.0 raised its own platform floor to iOS 18
and renamed no public symbols, so the floor was the whole cost. v1.0.0 still
supports iOS 17; iOS 17 devices keep that build and stop receiving updates.
Read AetherEngine's floor from `Package.swift` at the tag, never from its
release notes — 7.13.0's notes said "iOS 17" while its manifest said 18.

## Commands

The Xcode project (`DionysusPlayer.xcodeproj`) is generated from `project.yml`
via XcodeGen rather than committed — this keeps project structure a readable
diff instead of an opaque `.pbxproj`. **Whenever `project.yml` changes, or the
set of source files changes, regenerate the project:**

```sh
xcodegen generate
```

To build/run, open the generated project and build the `DionysusPlayer`
scheme (target iOS 18+):

```sh
open DionysusPlayer.xcodeproj
```

Two test targets exist: `DionysusPlayerTests` (XCTest unit tests, host-app
style) and `DionysusPlayerUITests` (XCUITest journeys). Three test plans live
in `TestPlans/` — `UnitTests` (the scheme default), `UITests-Smoke` (the PR
gate) and `UITests-Full`. See `TESTING.md` for the strategy and what's
covered. Run it from Xcode with
the `DionysusPlayer` scheme (Cmd+U), or from the CLI once a Simulator runtime
is available:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Pinning AetherEngine

**`project.yml` pins AetherEngine with `version:` (XcodeGen's spelling of
SPM's `.exact` requirement), not a `from:` range.** This used to be
`from: 6.5.5` (SPM's "up to next major" rule), which meant a cold resolve —
every CI run, since `Package.resolved` is gitignored along with the rest of
the generated `.xcodeproj` (see above) — could silently land on whatever the
newest `6.x` release happened to be, with zero commit in this repo to review
or even notice. Confirmed live more than once (PR #147, 2026-08-28: CI
resolved `6.54.0` against a checked-in `6.52.0` pin with no other
AetherEngine-related change on the branch at all). An exact pin makes that
structurally impossible: a cold resolve always lands on this exact version.

**Bumping the pin is automated but still reviewed.** The "Bump AetherEngine"
workflow (`.github/workflows/aetherengine-bump.yml`) runs weekly, finds the
newest release tag within the *current* major (what `from: <major>.0.0`
would resolve, prereleases excluded), and if that's newer than the pin,
opens a PR bumping `project.yml`'s one line. It never proposes a major bump
(8.0.0) — that's exactly where AetherEngine's public API is allowed to break
per semver, so project.yml's own comment on the `packages:` block treats it
as a deliberate manual edit. A bump PR goes through the same `pr-checks.yml`
gate as any other PR before it can merge — nothing lands unbuilt/untested.

**The version shown in "stats for nerds" comes from the engine itself.**
`PlaybackStatsOverlay` reads `AetherEngine.version` (added upstream in 7.3.0)
through the `AetherEngineVersion` shim in `Core/Playback/`, so nothing needs
regenerating after a bump. This replaced a checked-in generated constant,
its regeneration script, and a `pr-checks.yml` drift gate — all of which
existed only because AetherEngine used to expose no version at all.
Upstream rewrites the literal in each release's prep commit and holds it to
the tag by test; it matched on every tag from 7.3.0 to 7.15.0.

### App version (SemVer)

The app's own version — shown on the Profile screen's footer via
`AppVersionInfo`/`AppVersion.swift` — follows SemVer, grounded in git tags
and wired into `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as far as
Apple's numeric-only version fields allow. This used to be the same
"stamp git branch/commit into the built Info.plist via a
postCompileScripts phase" trick as AetherEngine's version above, and hit
the identical build-graph-ordering bug; it's since been replaced with the
same fix (a checked-in generated file, refreshed by
`Scripts/update-version.sh`). See `VERSIONING.md` for the full scheme —
tag convention, alpha/beta/final release flow, and how the version reaches
the built app.

`stable` is the branch final `vX.Y.Z` releases are tagged from — it moves
forward only via the `develop → stable` promotion PR (`promote-to-stable.yml`,
see `VERSIONING.md`), and should never be branched from or committed to
directly. `develop` is the default branch and where all day-to-day work
happens; `stable` stays dormant until there's a final release to cut.

**Cutting a release is one annotated tag push.** `release.yml` stamps the
version from the tag, builds and tests it, archives and signs it, uploads it
to App Store Connect (where it becomes a TestFlight build), and publishes the
GitHub Release. Nothing needs stamping, predicting, or verifying beforehand —
if you find yourself adding a "stamp before tagging" step, read
`VERSIONING.md`'s "Why there is no longer a release-prep PR" first; that
coupling was removed deliberately after its build-number prediction broke
three times.

Three things about it that aren't obvious from the workflow file:

- **The annotated tag's message is the release notes.** It becomes both the
  GitHub Release body and TestFlight's "What to Test", so write it for a
  tester. A lightweight tag (`git tag` without `-a`) silently produces an
  empty summary.
- **`Config/Version.xcconfig` and `AppVersion.swift` are expected to lag**
  between releases. CI stamps the shipped build; the checked-in copies are a
  local-dev convenience and report honest off-tag metadata
  (`0.8.0-alpha.1+12.gabc1234`). Don't "fix" them to match.
- **The archive signs automatically, the export signs manually.** That
  asymmetry is deliberate — automatic export fails with a cloud-signing
  permission error. It depends on a provisioning profile named *by string* in
  `Config/ExportOptions.plist`, which, along with the distribution
  certificate, expires 2027-08-30. See `VERSIONING.md`'s "Signing setup".

## UI verification

**The regression net is `DionysusPlayerUITests`** — an XCUITest suite driving
the real app against an in-process stub server and a fake playback engine.
See `TESTING.md`'s "UI tests" section for the harness, the launch arguments,
the fixture catalogue and the selector rules. Run it with
`-testPlan UITests-Smoke` (the PR gate) or `-testPlan UITests-Full`.

**If a change touches a view, add or update a journey there** rather than
verifying once by hand and moving on. Two rules that are not guessable and
cost a debugging session each: never select on an accessibility *label*
(those are localized), and never put an identifier on a screen-root
container (it sometimes overwrites every descendant's own). Both are
documented in `A11yID`.

**Accessibility is gated too.** `AccessibilityAuditTests` runs
`performAccessibilityAudit()` over every screen, on the *structural* audit
types only — unlabeled controls, labels that aren't human-readable, wrong
traits, hit regions. A new view with a decorative `Image(systemName:)` and
no `.accessibilityHidden(true)` will fail it, because SwiftUI falls back to
the SF Symbol's name and VoiceOver reads it aloud. Contrast, Dynamic Type
and text clipping are deliberately *not* gated — 145 known findings that
come from app-wide design choices rather than mistakes; see `TESTING.md`'s
"Accessibility audits" before widening the set or adding a suppression.

Everything below is for *exploratory* checking — seeing a new design, or
chasing something the suite can't express. It is not a substitute for a
committed test.

For visual or interactive changes, prefer the `ios-simulator-skill` (when
available) over ad hoc `simctl`/coordinate-tap scripting: it drives the
Simulator via `idb`'s accessibility tree (find-by-text/type/id, then tap)
rather than blind pixel coordinates, which survives layout changes far
better. It needs `idb-companion` installed (`brew tap facebook/fb && brew
install idb-companion`) plus the `idb` Python client — install that via
`pipx install --python $(which python3.12) fb-idb` specifically; pipx's
default (newer) Python fails at runtime with an `asyncio.get_event_loop()`
error. Start a session with `idb_companion --udid <udid> &` then
`idb connect <udid>` before the first call.

Reuse a single booted Simulator instance across tasks rather than
booting/quitting one per session: check `xcrun simctl list devices | grep
Booted` first and target whatever's already running (same device for
`xcodebuild -destination`/`simctl install`/`simctl launch`), and don't
`simctl shutdown` or quit Simulator.app when a task finishes. One instance
reuses fine back-to-back — closing and relaunching only wastes boot time and
throws away useful state (installed build, current screen).

Confirmed (2026-08-12) working well for Login, Home, Search, Profile, and
detail-page screens — real accessibility elements, real taps.

An earlier version of this section said `idb` returns an empty accessibility
tree on the Player screen and that automated taps there were hopeless. **That
is no longer true** — it was disproven on 2026-09-05, and XCUITest drives the
player's controls fine under the UI-test harness, where the fake playback
engine means there is no video surface at all. If a real AetherEngine session
*is* on screen, the surface repaints continuously and automation there is
still worth avoiding; use the harness instead of fighting it.

## Architecture

The app is a straight linear state machine at the top, with feature modules
underneath that each follow the same MVVM shape.

### App-level flow (`App/`)

`AppState` (`App/AppState.swift`) is the single source of truth for where the
user is in the app, driven by a `Phase` enum: `.serverSetup` → `.login` →
`.main`. It also owns the `JellyfinAPIClient` instance, since the client's
base URL depends on which server was configured — there is one client per
configured server, created in `completeServerSetup` and recreated on
`start()`. `RootView` switches on `appState.phase`, but shows `SplashView`
(`App/SplashView.swift`) instead whenever `appState.isRestoringSession` is
true — a branded gradient/glass splash covering the brief window before the
phase is known at all, rather than a phase of its own. Session persistence
(`ServerSessionStore`, `Core/Persistence/`) splits storage by sensitivity:
server config in `UserDefaults`, credentials/access token in the Keychain
(`KeychainStore`). On launch, `AppState.start()` restores the server, then
attempts silent sign-in with stored credentials before falling back to the
login screen.

### Networking (`Core/Networking/`)

`JellyfinAPIClient` is an `actor` — all network calls are async and
serialized through it, and it holds mutable state (`accessToken`) that gets
set post-authentication. It's a thin hand-written wrapper over Jellyfin's
REST API (no generated SDK), intentionally scoped to only what the app needs:
server info, auth, browsing/search, playback info, progress reporting, and
(diagnostics-only, for `PlaybackStatsOverlay`'s Streaming section) reading
back the server's own live session/transcode state via `/Sessions`.

`sendRaw` (every request funnels through it) auto-recovers from a 401 on any
token-bearing request: it remembers whatever credentials last succeeded via
`authenticate(...)` and, on a 401, silently re-authenticates and retries with
backoff (`reauthBackoffSchedule`) before giving up as `.notAuthenticated` —
confirmed live against a heavily-shared public demo server that a session
token can be invalidated server-side for reasons entirely outside this app's
control. Concurrent 401s coalesce into one re-authentication via an
in-flight `Task` rather than each racing to sign in independently.
`authenticate(...)`'s own 401 (a wrong password at first sign-in) is
unaffected — it's sent with `requiresAuth: false`, so it never carries the
token header this keys off. `AppState.signOut()` clears the remembered
credentials on the client it reuses across a sign-out/sign-back-in, so a
request still in flight around sign-out can't silently re-authenticate as
the just-signed-out user.
`ImageURLBuilder` is deliberately *not* actor-isolated — it's a plain struct
snapshotted via `client.makeImageURLBuilder()` so SwiftUI views can build
image URLs synchronously without hopping through the actor on every render.

**Live playback** negotiates with the server by default, via a
`StreamPreferenceStore.decisionMode` setting (Profile → Streaming) that
switches between **Allow Transcoding** (default since 2026-08-28 —
`DeviceProfileBuilder.build(maxStreamingBitrate:)` —
`Core/Networking/DeviceProfile.swift` — builds a real `DeviceProfile`, sent
on `/PlaybackInfo` so Jellyfin can choose direct play or a transcode;
`PlayerViewModel.start()` branches on whether the response carries a
`MediaSourceInfo.transcodingUrl`) and **Direct Play Always**
(`streamURL(itemID:mediaSourceID:container:)` builds a static stream URL —
`Static=true` — and AetherEngine decodes whatever comes back; no
`DeviceProfile` sent, the app's original, non-negotiated behavior — still
available for anyone who wants to force it). A
server-chosen transcode is consumed via AetherEngine's `nativeRemoteHLS`
bypass (`AetherPlaybackEngine.load(..., isRemoteHLS: true)` — the playlist
goes straight to AVPlayer, no local FFmpeg demux) rather than downloaded
and re-muxed; the HLS transcode target itself is fragmented MP4 (H.264 or
HEVC), never MPEG-TS — see that file's `hlsTranscode` doc comment for why
(Apple's HLS Authoring Spec doesn't support HEVC-in-MPEG-TS on AVPlayer at
all). `PlaybackStats.route` in the "stats for nerds" overlay shows which
AetherEngine pipeline (`.remoteBypass`/`.loopback`/...) actually ended up
serving a session — `playbackBackend` alone can't distinguish them.

**Downloads are a separate path that always transcodes** —
`downloadStreamURL(...)` (`Static=false`, HEVC/MP4, resolution + bitrate capped
to the user's chosen tier). Don't read the playback paragraph above as a
whole-app statement: the app both direct-plays and transcodes, just in
different places. The tiers, the bitrate ladder behind them, and why the
default differs between iPhone and iPad are documented in `DOWNLOADS.md` —
**read it before changing any number in `DownloadTypes.swift`**, since the
ladder is derived from a single bits-per-pixel rule rather than chosen
per-rung, and a locally-sensible tweak breaks that. `DownloadTypesTests`
asserts the rule directly.

### Image loading & placeholders

`RemoteImageLoader` (`Core/Networking/`) is the single choke point for every
network image (posters, backdrops, logos, cast photos) — an actor with its
own tuned `URLSession`, retry-with-backoff for transient failures, an
in-memory `NSCache` (byte-cost-limited, not count-limited), and in-flight
de-duplication, all built to survive a burst of concurrent requests against
a self-hosted server on first launch. `image(for:maxAttempts:retryBaseDelay:)`
takes optional per-call overrides on top of its own configured defaults —
used by `AsyncRemoteImage.RetryPatience`/`LogoImageView`'s `retryPatience`
(`.standard` vs `.extended`) to give the single hero backdrop/logo per
screen a longer retry budget than every other, smaller image, without
multiplying a cold server's initial request burst. `AsyncRemoteImage`
(network) and `LocalFileImage` (local/offline `file://` artwork — a
synchronous `ImageIO` decode, deliberately not routed through
`RemoteImageLoader`, whose retry logic assumes an `HTTPURLResponse`) are the
two view-level wrappers everything else uses; `LogoImageView` layers on top
of `AsyncRemoteImage`'s network path for the fade-in/fallback-text behavior
logos need.

Every one of those three renders `MediaPlaceholderBox`
(`Shared/Components/`) for its loading/failure state — a content-type SF
Symbol glyph (`BaseItemKind.placeholderSystemImage`, e.g. `film` for a
movie, `tv` for a show, `person.fill` for cast) tinted `.dionysusHighlight`,
never a generic spinner or blank gray box. The glyph itself shimmers (via
the `SwiftUI-Shimmer` package's `.shimmering()` modifier, scoped to the
glyph rather than the whole tile — deliberately calmer than shimmering the
full box) while a fetch is still outstanding, and settles to a static,
higher-opacity glyph once it's failed or known not to exist at all (`isSettled`
— gated on Reduce Motion, matching every other animated effect in this
part of the app). When adding a new image display site, pass a
`placeholderSystemImage` that matches the content type rather than leaving
the generic default.

`LogoImageView`'s `fallback` view (usually title text, via
`BackdropLogoOverlay`) renders immediately while the logo is loading, not
just after a definitive failure — cross-fading to the real logo once it
resolves, reduce-motion aware.

### Playback (`Core/Playback/`)

`PlaybackEngine` is a protocol wrapping AetherEngine so feature code never
depends on the third-party library directly — `AetherPlaybackEngine` is the
real adapter, `PreviewPlaybackEngine` (`#if DEBUG`-gated) is a fake used only
in SwiftUI previews. When changing playback behavior, change the protocol
and both conformers; `PlayerViewModel` should only ever talk to the
`PlaybackEngine` abstraction.

Picture in Picture is wired for AetherEngine's native (AVPlayer) route only —
covers HEVC/H.264, effectively all of this app's real content today.
`AetherPlaybackEngine` owns the `AVPictureInPictureController` (built around
`AetherEngine.nativePlayerLayer`, rebuilt whenever `engine.$currentAVPlayer`
re-emits) behind a small `NSObject` delegate proxy (`PictureInPictureDelegateProxy`
in the same file) — `AetherPlaybackEngine` itself can't conform to the
Objective-C `AVPictureInPictureControllerDelegate` directly without giving up
its throwing `init()`. On PiP start/stop it calls AetherEngine's own
`setNativeSubtitleRendering(_:)`, the documented host hook for handing
whichever subtitle track the app has selected to AVKit as a native WebVTT
rendition — the app's own `SubtitleOverlayView` isn't visible inside the
captured layer. The software (sample-buffer) route — AV1/VP9/interlaced/
legacy sources — has no PiP support yet; the button in `PlayerControlsOverlay`
is omitted there for free (not shown disabled), since `isPictureInPicturePossible`
never turns true without a controller, which never gets built without a
native player layer.

`AetherPlaybackEngine` also opts into owning the native video path's system
Now-Playing session (`engine.ownsVideoNowPlayingSession = true`, set before
`load()`) — required for the lock screen/Control Center card to show
anything at all, since this app renders its own transport chrome rather than
going through `AVPlayerViewController` (which would get Now-Playing from
AVKit for free, and must NOT also opt into a session of its own — see
AetherEngine's own doc comment on why the default is off). Opting in makes
the *host* responsible for wiring transport commands too: `AetherPlaybackEngine`
registers play/pause/skip against `engine.videoNowPlayingSession
.remoteCommandCenter` (re-registered on the same `$currentAVPlayer` signal
PiP rebuilds on), and `PlayerViewModel.start()` stages title/subtitle
(`MediaItem.railTitle`/`.railSubtitle`) via `engine.setNowPlayingInfo(title:
subtitle:artwork:)` immediately, with artwork following separately once
fetched through `RemoteImageLoader`.

### Subtitles

Two renderers, split by codec. **ASS/SSA goes to libass**
(`ASSSubtitleRenderSession`, on the `swift-ass-renderer` package); everything
else — SubRip, WebVTT, teletext, PGS and other bitmap formats — keeps
rendering through `SubtitleOverlayView`'s own SwiftUI path on the cues
AetherEngine publishes. Four things about that split are load-bearing and none
are guessable:

- **`LoadOptions.preserveASSMarkup` is deliberately NOT set.** The app fetches
  the complete `.ass` script itself instead, so AetherEngine's cue path stays
  exactly as it was for every track. Jellyfin extracts any subtitle stream —
  embedded ones included — via `JellyfinAPIClient.subtitleURL`, and
  `DownloadManager` already stores every non-bitmap track as a sidecar, so the
  script is always available without it. An earlier version of this bullet gave
  a second reason — that turning the flag on would flip the session's embedded
  SubRip tracks to raw event lines too, because it is codec-gated on the sidecar
  path but not on the embedded one (AetherEngine#587). That was wrong, and the
  issue was refuted upstream by measurement. The gate is in
  `EmbeddedSubtitleDecoder.init`, which narrows the flag once into a stored
  property *of the same name*, so the emit site downstream reads as though
  nothing had been checked when it is reading an already-gated value. Don't
  re-raise it from reading that line; upstream has since renamed the property to
  `emitsRawASSLines`. The flag is unnecessary here, not dangerous.
- **A whole script, loaded once — never `reloadTrack` per cue.**
  `swift-ass-renderer` exposes only whole-script load/reload, and `reloadTrack`
  frees the current track synchronously, so feeding it a growing script blinks
  the subtitle off on every rebuild. Reloading only happens on a geometry
  change, which is cheap (0.4–1.7ms for a 218KB script) and deliberately does
  not clear the outgoing frame.
- **Engine track ids match nothing on the server**, so a selected track is
  mapped back by *ordinal*, two different ways. A track AetherEngine demuxed
  out of the container pairs with its `MediaStream` among *embedded ASS*
  entries (`jellyfinStream(forTrack:engineTracks:mediaStreams:)`); a sidecar
  this app registered pairs with what it was built from, among *externals*
  (`registeredSidecar(forTrack:engineTracks:registered:)`, shared by the
  streaming and offline paths). Filtering both sides identically is what makes
  either ordinal meaningful; counting the wrong tracks shifts it and silently
  serves a different track's script, which reads as a bad file rather than a
  mapping bug. `ASSSubtitleMappingTests` pins both.
- **On a transcode the container's own text tracks must be registered as
  sidecars.** The app plays the server's HLS through AVPlayer, and that
  playlist carries no rendition for them, so nothing demuxes them — every
  embedded SubRip and ASS track disappeared from the picker until
  `externalSubtitleStreams(from:isRemoteHLS:)` started registering them.
  Jellyfin says which: asked with this app's `DeviceProfile` it answers
  `MediaStream.deliveryMethod == "External"` for exactly those streams (and
  `"Encode"` for the bitmap ones it burns in). That field is **not**
  `isExternal`, which says where the stream lives in the library rather than
  how it reaches the player — an embedded ASS track on a transcode is
  `isExternal: false` with `deliveryMethod: "External"`, and filtering on the
  former is what dropped them. The route gate is equally load-bearing: direct
  play reports the same `"External"` for the same streams, where the engine
  has already listed them, so registering sidecars there shows every track
  twice. Confirmed against 10.11.11, both routes. AetherEngine supports
  sidecars on the `nativeRemoteHLS` bypass as of 6.14.0 (its #316), which
  rewrites the master playlist to carry them.
- **A cold fetch can take over a minute.** Jellyfin extracts an embedded track
  on demand and caches it: 70s measured against a 4K remux, 0.03s after. The
  request therefore carries its own 180s timeout (`URLSession`'s 60s default
  cut it off just before it finished), and until the script lands the cue path
  renders the same track unstyled, so there is never a dead screen.

**On a transcode, libass is timed off AVPlayer's own subtitle timing, not the
playhead.** There the engine's `sourceTime` is AVPlayer's item time, which runs
*ahead of the picture* after a seek: Jellyfin restarts the transcode at the
source keyframe before the requested segment, and AVPlayer anchors its timeline
to the first segment it loads, so the gap is that segment's slot minus its
keyframe — measured anywhere from 1.1s to 8.3s on one film. It keeps that anchor
across later job restarts, so reading segment timestamps can't recover it (tried
and disproven). What does know it is AVPlayer's timing of the WebVTT rendition
AetherEngine injects for the same track, which is why unstyled subtitles never
drifted. So on that route the rendition stays selected with an app-owned
`AVPlayerItemLegibleOutput` suppressing its drawing
(`setNativeSubtitleCapture`), and `ASSCueTimingCalibrator` matches each line it
reports to the script to measure the offset, holding styled lines back after a
seek until the first one arrives (5s at most). Two traps, both found on device:
an output that starts suppressing while AVPlayer is drawing a line freezes that
line on screen for good — not even a deselect clears it afterwards — so the
rendition is deselected *before* the output attaches; and a (re)attached output
re-delivers the line on screen as though it had just started, which must not be
measured. Direct play and offline never need any of this: there `sourceTime` is
the source PTS.

**The user can turn styling off** — Profile → Playback → Advanced → Subtitle
Styling, on by default (`styledASSSubtitlesEnabledDefault`). It sits in
Advanced because it is an escape hatch for a script whose typesetting fights
the phone, not a taste preference. There is exactly one gate,
`PlayerViewModel.handleSubtitleTrackChange`'s `isStyledASSEnabled()` check, and
turning it off makes an ASS track behave like a SubRip one — it still renders,
through `SubtitleOverlayView`'s own path, just unstyled. Read at each track
selection rather than captured, which is as live as it can be observed to be:
the player is a `fullScreenCover` and settings live in a tab behind it, so the
two are never on screen together. Note `isStyledASSEnabled` reads
`object(forKey:)` before `bool(forKey:)` — the latter reports `false` for a key
that was never written, which would ship the feature off for everyone who never
opened Settings.

**Geometry.** libass gets a frame running from the picture's top edge to the
bottom of the overlay, with `ass_set_margins` describing the bar below the
picture and `ass_set_use_margins` on — the documented mechanism for subtitles
in the letterbox bar. Regular dialogue moves into that bar while `\pos` signs,
which are positioned rather than regular, stay anchored to the picture.

**The drawable region is the picture intersected with the safe area**, with the
bottom raised for the transport chrome. The overlay itself must ignore the safe
area to sit over a full-bleed video, so nothing else keeps subtitles off the
rounded corners and the sensor housing — and in landscape the picture fills the
screen, so a corner-aligned sign drew *underneath* them and was physically cut
off. That is invisible in a screenshot, because the framebuffer has no corners;
it only shows on the device. Note the insets come from the window, not from a
`GeometryReader`: one inside an `ignoresSafeArea` view reports zeroes (measured,
not assumed).

**The margins are signed, and in landscape the bottom one is negative.** libass
documents a negative margin as "the frame is inside the video, i.e. the video
has been cropped", which is exactly what landscape is: the picture fills the
screen, so the frame — which stops short of the transport chrome — is shorter
than the picture. Clamping that to zero tells libass the picture ends where the
frame does and maps every `\pos` sign into a too-short rectangle (measured: a
sign at y 20–34 against a correct 29–49, and 30% undersized). Portrait margins
are positive, so the clamp never fired there and the defect was landscape-only.
`ASSSubtitleGeometryTests` pins both orientations.

**Regular events take their font scale from the frame, so landscape needs
`ass_set_font_scale`.** libass scales a regular event to whichever of the frame
and the video area is smaller, while a positioned one always scales to the
video area. In portrait the frame is the taller of the two (it includes the bar
below the picture), so the two agree. In landscape the picture fills the screen
and the frame stops short of the chrome, so dialogue rendered about 7% small at
rest and 28% small with the controls up — measured by rendered *width*, since
glyph heights are quantised too coarsely to see a 7% difference.
`Geometry.fontScale` (`max(1, pictureHeight / frameHeight)`) compensates,
restoring all three of dialogue, `\pos` and `\an8` to the widths they render
at against a full-height frame, and resolving to exactly 1 in portrait so the
common case is untouched. Positioned events are unaffected by it — verified by
measurement, not assumed. Note `ass_set_storage_size` is *not* the knob for
this: it affects aspect ratio and blur, not scale.

An earlier version of this section stated the opposite — that there was "no way
in libass' model to confine regular events to a shorter frame while scaling
them to the full picture". That was wrong; `ass_set_font_scale` is exactly that
knob, and it was missed rather than ruled out.

The frame starts at the picture rather than the overlay so there is **no top
margin**. `use_margins` relocates every *regular* event into the margins and
top-aligned events are regular, so a top margin sends an `\an8` sign into the
bar above the picture — measured at y 9–23 against a picture starting at 324.
The cost is a bare `\an5`, which centres in the frame and so sits low; that is
a real trade in libass' model (only a zero top margin places `\an8` right, only
a symmetric one places `\an5` right, and the bottom bar rules out both being
zero) settled on frequency — typesetting uses `\an8` constantly, while a bare
`\an5` is rare and usually carries a `\pos`, which is exempt anyway. The bottom clearance is **measured**, not constant —
`PlayerControlsOverlay` publishes its chrome's top edge via
`BottomChromeTopKey`, because that chrome's height varies with content (the
chapter/format row is ~48pt and only present sometimes) and because the
controls respect the safe area while the subtitle overlay ignores it.

**Embedded fonts are registered with CoreText, not fontconfig.**
`engine.fontAttachments` (populated from AetherEngine's probe regardless of
`preserveASSMarkup`) are written to a temp directory and registered with
`CTFontManagerRegisterFontsForURL` at `.process` scope. The fontconfig
provider would resolve embedded faces at the cost of every system one — the
wrapper's generated `fonts.conf` declares exactly one directory and no system
font paths. Registration is process-global, so teardown unregisters precisely
what it registered.

**Two routes have no attachments to probe, and both fetch them instead.** A
server-side transcode plays the server's fMP4 HLS through AVPlayer, so nothing
local ever demuxes the source container; offline, the downloaded file is MP4,
which has no attachment streams at all. AetherEngine reports an empty list in
both cases. `MediaSourceInfo.mediaAttachments` carries them regardless of route
(verified live against 10.11.11 — present on the transcode path as well as the
direct-play one), so live playback fetches them from
`/Videos/{id}/{source}/Attachments/{index}` and `DownloadManager` stores them as
sidecars at enqueue, next to the subtitles and for the same reason. Build that
URL from ids rather than reading `MediaAttachment.deliveryUrl`, which the server
fills only when the `/PlaybackInfo` request carried a `DeviceProfile` — the same
trap `MediaStream`'s own delivery URL sets.

Four things about that are load-bearing:

- **The engine's own attachments win whenever it has any** — see
  `PlayerViewModel.assFonts(engineAttachments:fetched:)`. Not a merge: on a
  direct play the two lists are the same faces out of the same container, so
  merging registers each one twice, and a container carrying fonts never probes
  to an empty list, so there is no partial case to serve.
- **Fonts never gate the script.** The script is applied the moment it lands and
  the fonts re-apply when they arrive, costing one extra parse (0.4–1.7ms) on
  the routes that fetch and nothing at all on the common path. Joining the two
  instead would hold a subtitle back for however long several megabytes of CJK
  faces take, purely to change how it looks. `StyledSubtitleJourneyTests`'
  `.slowSubtitleFonts` journey pins this, and was confirmed to fail against a
  build that waits.
- **Not every attachment is a font.** Cover art (`cover.jpg`) is the common
  other case. `JellyfinAPIClient.isFontAttachment` takes any of codec, MIME type
  or filename extension as sufficient — none is reliable alone — with WOFF as
  the single veto, since `CTFontManager` can't register it whatever the codec
  column says.
- **Attachments are rare.** 4 of 932 MKVs in the library this was built against
  carry any, so all of this has to stay free when there are none.


### Features (`Features/*`)

Each feature folder is a vertical slice: a SwiftUI `View` + an `@Observable`
`@MainActor` ViewModel that owns a `JellyfinAPIClient` reference and exposes a
`LoadState`-style enum (`idle`/`loading`/`loaded`/`failed`) for the view to
switch on. ViewModels are constructed with an already-resolved `client` and
`userID` (see `HomeViewModel.init`) rather than reaching into `AppState`
themselves — when adding a new feature screen, follow this pattern rather
than injecting `AppState` directly into ViewModels.

Rail/grid selection logic (what shows up on Home, in what order) is
explicitly a placeholder per the ViewModel doc comments — don't over-invest
in "correct" curation logic there without checking if it's being redesigned.

`CollectionGridView`/`CollectionGridViewModel` (Movies/Shows/Collections
grids) combine a server-side sort (field + ascending/descending, refetched on
change) with client-side filtering across up to five facets — Genre, Studio
(labeled "Network" instead when the query is Series-typed — Jellyfin has no
separate Network field; a show's network lives in the same `Studios` field a
movie's studio does), Decade, Watched, and Favorites. All five are
`Menu`-based pills; Favorites offers All Items/Favorites/Non-Favorites (an
`Optional<CollectionFavoriteStatus>` selection, mirroring Watched's
`Optional<CollectionWatchStatus>` shape) rather than a plain on/off toggle,
so it can filter *out* favorites too. All five are *cascading*: each facet's
own available-options list is computed by applying every *other* active
facet to `items` (never itself — see `CollectionGridViewModel
.matchingItems`'s doc comment), so no combination the UI offers can ever
funnel down to zero results. When adding another facet here, follow that
same "exclude yourself, apply the rest" shape rather than a flat AND filter,
or the funnel guarantee breaks.

### Transient confirmations (`Shared/Components/Toast.swift`)

`ToastCenter.shared.post(Toast(message:))` shows a brief, self-dismissing
capsule; `ToastHost` renders it, applied once as an overlay in `MainTabView`
so a toast outlives whatever raised it. That indirection is the point — the
first thing to use it (adding to a playlist) finishes by *dismissing its own
sheet*, so a confirmation owned by that sheet would be torn down in the same
frame it appeared.

**Use it for "that worked" on an action whose own UI has already gone**, not
as a general notification channel: it can't be dismissed by anything but a
tap or its own timer, and a second post replaces the first rather than
queueing. A haptic alongside it is fine (`AddToPlaylistSheet` does both), but
a haptic alone is not — it says nothing to a user who has them off. Posting
also fires a VoiceOver announcement, since a view that disappears on its own
can't be found by focus.

### Playlist editing, and what Jellyfin actually gates

The app can add items to a playlist (`AssetActionsButton` →
`AddToPlaylistSheet`) and remove them (`PlaylistItemList`'s long-press menu).
Three facts about the server side are load-bearing and none are guessable
from the API docs — all were read out of `jellyfin/jellyfin`'s
`PlaylistsController.cs`/`PlaylistManager.cs` and cross-checked against
`jellyfin-web`'s `playlisteditor.ts`:

- **Creating a playlist has no permission gate at all.** `POST /Playlists`
  is `[Authorize]`-only; `UserPolicy` has `EnableCollectionManagement`, which
  governs *collections*, not playlists. So every signed-in user can always
  create one — which is why "Add to Playlist" renders unconditionally, and
  why the toolbar's `ellipsis` overflow appears exactly when the user *also*
  has delete rights. Don't add a permission check for it.
- **Adding to and removing from an existing playlist share one gate**:
  `OwnerUserId == caller || Shares.Any(CanEdit && caller)`, refused as a
  clean 403. There is no bulk "which playlists may I edit" query and no DTO
  that exposes `OwnerUserId`, so the only way to answer it is one
  `GET /Playlists/{id}/Users/{me}` per playlist — an N+1 that Jellyfin's own
  web client also performs. `JellyfinAPIClient.editablePlaylists` does it
  with capped concurrency and a fail-soft per check, the same shape
  `collectionsContaining` settled on.
- **Posting a Series or Season id adds every episode beneath it**, in one
  request: `Playlist.GetPlaylistItems` expands any folder-shaped item
  recursively server-side. "Add the whole show" must therefore send the
  show's own id — never a client-side enumeration of episodes, which would
  both duplicate the server's work and be wrong for a show whose episodes
  this client hasn't fetched.

One more, easy to get wrong silently: `CreatePlaylistDto.IsPublic`
initializes to **`true`** server-side, so `CreatePlaylistRequest.isPublic` is
non-optional and always encoded. Omitting it publishes the playlist to every
user on the server. New playlists default to private here, matching
`jellyfin-web`'s own unchecked "Public" box.

### Navigation (`Shared/Navigation/`)

Single shared `AppRoute` enum (`collection`, `assetDetail`, `downloadedAsset`,
`downloadedShow`, `downloadedSeason`) used as the
`navigationDestination(for:)` type across `MainTabView`'s four tabs
(Home/Search/Downloads/Profile). Home, Search and Downloads each own a
`NavigationStack`; Profile owns its own container, because that container
differs by device (a `NavigationSplitView` on iPad). Adding a new
pushable destination means adding a case to `AppRoute` and a branch in
`AppRouteDestinationView`, not a per-feature navigation type.

### Models (`Core/Models/`)

Jellyfin API DTOs (`JellyfinModels.swift`) are kept separate from the app's
own lighter view-facing models (e.g. `MediaItem`, `MediaCollectionRail`) —
DTOs get mapped into app models (usually via an `init(dto:images:)`
initializer) rather than passed directly to views.

**`BaseItemDto`/`MediaItem` equality is structural, and must stay that
way.** Both look like obvious candidates for a cheap id-only `==` (both
did, once). Don't: SwiftUI prefers a stored property's own `==` over its
internal comparison when deciding whether a view changed, and `MediaItem`
is the stored property of essentially every view in the app while
`[MediaItem]` is what `ForEach(rail.items)` diffs on. An id-only `==`
promises SwiftUI that nothing under a stable id is worth repainting —
false for `userData` after playback and for `mediaSources`/`people` when
`AssetDetailViewModel` swaps its preloaded item for the full fetch. The
symptom is a view frozen on stale data while every layer underneath it
holds the correct value, which reads convincingly as a timing bug and
isn't one; it cost six separate `.id(...)` workarounds and a spell of
`os.Logger` calls kept in production before the shared cause was found.
`hash(into:)` stays id-only alongside it — the legal direction for the
`Hashable` contract. See `MediaItem.==`'s doc comment.

### Localization

User-facing strings go through a String Catalog
(`DionysusPlayer/Resources/Localizable.xcstrings`) — only English is
populated for now, but a translation vendor can be plugged in later without
code changes (add a language to the catalog, import their XLIFF). Two
conventions, depending on layer:

- In SwiftUI views, write plain string literals to `Text`/`Button`/`Label`/
  `Section`/`.navigationTitle`/etc. — their `LocalizedStringKey`-typed
  overload is what Xcode auto-extracts into the catalog. This does *not*
  apply to a computed `String` value (e.g. `Text(foo ?? "Bar")`) or a
  parameter on a custom view typed `String` rather than
  `LocalizedStringKey` — neither gets auto-extracted even with a literal
  argument.
- Everywhere else (ViewModels, error messages, model-layer display strings,
  and any of the `String`-typed cases above), wrap the literal in
  `String(localized: "...")` instead.

Server/user-supplied content (item titles, library names, cast/crew names,
...) and industry-standard technical terms or formatted data (codec names,
HDR format names, timecodes, "S1:E4"-style labels, the app's own name)
should stay as plain strings, not wrapped — see `MediaItem.swift` and
`PlayerControlsOverlay.swift` for the reasoning at each such case.

The catalog only gets populated by an Xcode.app IDE build (**Cmd+B**), not
by `xcodebuild` from the CLI — extraction-into-catalog is an IDE/source-editor
feature, not part of the command-line build system. Don't take a build-time
absence of new strings in `Localizable.xcstrings` as a sign something's
wrong; open the project in Xcode and build once to sync it.

**Sync the catalog in the same PR that adds the strings, not as a
follow-up.** Because extraction is IDE-only, neither `pr-checks.yml` nor
`release.yml` (both CLI `xcodebuild`) can ever catch or commit this — it
used to be deferred to a separate "Sync Localizable.xcstrings catalog" PR
discovered well after the fact (e.g. #106, #119), which is exactly the kind
of release-day cleanup this project is trying to eliminate (see
`VERSIONING.md`'s release flow). If a PR adds or changes any
`Text`/`String(localized:)` literal, open the project in Xcode.app and
build once (Cmd+B) before opening the PR, and include the resulting
`Localizable.xcstrings` diff in it.

## Privacy policy maintenance

`PRIVACY.md` (repo root) is the app's App Store-required privacy policy,
also reachable in-app from Profile → Privacy Policy
(`DionysusPlayer/Resources/PRIVACY.md` is a symlink to the root file, same
single-source-of-truth pattern as `LICENSE`/`LicenseView`). It was written
by auditing the app's actual data collection/storage/network behavior, not
from a generic template — if that behavior changes, the document goes
stale in a way nothing will catch automatically (no CI check compares them,
the same gap `Localizable.xcstrings` used to have above).

**Update `PRIVACY.md` in the same PR** as any change that adds a new stored
identifier, a new `NS*UsageDescription`/permission, a new SDK or third-party
dependency, or any network destination other than the user's configured
Jellyfin server — rather than letting it drift and fixing it in a later
cleanup PR.

`PrivacyPolicyView` renders `PRIVACY.md` with a small hand-written
line-by-line Markdown renderer (headers/bold/italic/links/bullets only)
rather than a third-party library — a deliberate call while it's the only
Markdown file bundled in-app (see the view's doc comment for why). **If a
second Markdown file gets bundled into the app** (another legal doc, a
changelog, release notes, etc.), revisit that call — a real Markdown
library (e.g. MarkdownUI) is worth the added dependency once there's more
than one document's worth of rendering to maintain, or once a document
needs constructs the hand-written renderer doesn't handle (nested lists,
code blocks, tables).

## Store screenshots

`store-screenshots/` (repo root) holds the finished App Store Connect
screenshot sets; `Scripts/store-screenshots/{gen.py,shot.swift}` plus the
`Scripts/render-store-screenshots.sh` wrapper is the tool that produces
them from raw Simulator captures. See README.md's "Store screenshots"
section for the two-step workflow (capture, then render) — this section is
only the parts that aren't obvious from reading the scripts themselves.

**Capture against the Jellyfin demo server
(`demo.jellyfin.org/stable`, user `demo`, no password), never a personal
server.** The screenshots are checked into the repo and published to App
Store Connect, so anything they show is effectively public; the demo
server's whole catalogue is public-domain/Creative Commons for exactly
this reason. This was a live correction mid-session once already — default
to the demo server for any future screenshot refresh rather than whatever
server the Simulator happens to already be signed into.

**The demo server has no HDR, multi-track, or chaptered content.** Its
`Movie`/`Episode` items are all SDR H.264, single audio track, no
subtitles, zero chapters (confirmed via a `/Users/{id}/Items` probe across
its ~140 items). A slide claiming Dolby Vision/HDR10/Atmos or showing
chapters/track-picker UI can't be captured live there — either accept the
copy describing the app's real capability (verified elsewhere, see the
top of this file) rather than what's on screen in that one frame, or skip
the claim. Don't invent HDR-looking source video to fake it.

**`xcrun simctl` has no orientation control.** The player slide needs a
landscape capture (a portrait screenshot of the player is ~70% black
bars). Rotate via Simulator's own UI — `osascript` driving Simulator's
Device ▸ Orientation menu works from a script — screenshot, then `sips -r
270 <file>` to correct the PNG's rotation before handing it to the render
step (`gen.py`'s landscape frame expects an already-upright image).

**iOS defers a download task created while the Simulator is
backgrounded** (same mechanism as `ios-defers-background-created-download-tasks`
in the downloads feature itself) — a Downloads-tab capture queued while
scripting another window will sit at "Preparing…" indefinitely. Foreground
the target Simulator window (`osascript` `perform action "AXRaise"`) and
give it real wall-clock time before capturing that slide.

**The demo server's own transcode jobs restart mid-download** for larger
titles (a `Downloading… 86%` row can drop back to "Preparing download…"
minutes later, unrelated to anything this app does) — expect it, and
either wait out another cycle or pick a shorter title for that slide
rather than treating it as a capture bug.

`gen.py`'s brand colors (`MAGENTA`/`AMBER`) are copied constants, not
computed from `BrandColors.swift` — if that palette changes, update both
by hand.

## Commit messages and pull request descriptions

**Never include a Claude session URL (`https://claude.ai/code/session_...`)
anywhere in a commit message or a PR description** — including as a
`Claude-Session:` trailer. It's an internal reference with no meaning to
anyone reading the repository, and it leaks the existence/id of an otherwise
private session. Git history is permanent and public, which makes a commit
trailer the worse of the two.

Attribution itself is fine and wanted: keep `Co-Authored-By: Claude ...` on
commits and the "Generated with Claude Code" line on PR descriptions. Only
the session link is excluded.

This overrides any per-session attribution instruction that asks for the
trailer — those are generated by the tooling rather than chosen here, and a
session that receives one should drop the session-URL line and keep the rest.
