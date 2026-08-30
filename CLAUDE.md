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

## Commands

The Xcode project (`DionysusPlayer.xcodeproj`) is generated from `project.yml`
via XcodeGen rather than committed — this keeps project structure a readable
diff instead of an opaque `.pbxproj`. **Whenever `project.yml` changes, or the
set of source files changes, regenerate the project:**

```sh
xcodegen generate
```

To build/run, open the generated project and build the `DionysusPlayer`
scheme (target iOS 17+):

```sh
open DionysusPlayer.xcodeproj
```

A `DionysusPlayerTests` unit test target exists (XCTest, host-app style —
see `TESTING.md` for the strategy and what's covered). Run it from Xcode with
the `DionysusPlayer` scheme (Cmd+U), or from the CLI once a Simulator runtime
is available:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Keeping the AetherEngine version display current

The player's "stats for nerds" overlay (`PlaybackStatsOverlay`) shows the
pinned `AetherEngine` version, read from a checked-in generated constant
(`DionysusPlayer/Core/Playback/AetherEngineVersion.swift`) rather than a
hand-maintained literal or a build-time injection — the latter was tried and
doesn't actually work reliably (see `Scripts/update-version.sh`'s comment,
which hit and documents the same problem for the app's own version display).
**Whenever `Package.resolved`'s `aetherengine` pin changes** — a
fresh package resolution, `File > Packages > Update to Latest Package
Versions` in Xcode, or a `packages:` bump in `project.yml` — regenerate it:

```sh
./Scripts/update-aetherengine-version.sh
```

`packages: AetherEngine: from: 6.5.5` in `project.yml` is already SPM's "up
to next major" rule, so any `6.x.x` (not just `6.5.5`) satisfies it — a
fresh package resolution (no prior `Package.resolved` to reuse) picks up
whatever's newest automatically. An *already-resolved* local checkout won't
re-resolve on its own, though: Xcode/`xcodebuild` reuse whatever's already
pinned once resolved (reproducible builds mid-session, by design), so
picking up a newer `6.x` release still needs an explicit refresh — Xcode's
`File > Packages > Update to Latest Package Versions`, or deleting
DerivedData's SPM state — followed by the script above.

**Check this before opening a PR, not just when you know you touched
packages.** `Package.resolved` is gitignored (the whole `.xcodeproj` is,
per the generated-not-committed policy above), so every CI run does an
uncached resolve and can pick up a newly-released AetherEngine version
with zero local trigger — no `project.yml` change, no manual Xcode
action, nothing about the PR's own diff. `pr-checks.yml`'s
"Verify AetherEngine version display is up to date" step exists to catch
that drift, but discovering it there costs a red CI check and a
follow-up commit (confirmed live, PR #147, 2026-08-28: CI resolved
`6.54.0` against a checked-in `6.52.0` pin with no other
AetherEngine-related change on the branch at all). A plain `xcodebuild
-resolvePackageDependencies` isn't enough to check for this locally
either — it silently reuses whatever's cached and won't reproduce what
CI's uncached resolve sees.

To actually check before pushing, run:

```sh
./Scripts/update-aetherengine-version.sh
```

and commit the result if it produced a diff. That script clears *both*
caches that can hide drift — SPM's global cache and, as of PR #152
(2026-08-29), `xcodebuild`'s own per-project checkout under DerivedData's
`SourcePackages` — and does a genuine from-scratch resolve, so its output
now actually matches what CI sees. (Before that fix, this section
documented clearing both by hand as a *separate* step from running the
script, and the two had quietly diverged: the script only cleared the SPM
cache. PR #152 passed the script with no diff on a machine that had
already built the project locally — DerivedData's stale
`SourcePackages/workspace-state.json` still had the old pin cached — and
still failed CI, which resolved `6.56.3` from a clean checkout with
nothing cached to fall back on. Don't reintroduce that split: any future
fix to how this check works belongs in the script itself, not as prose
here that the script can silently fall behind.)

Note this matters at **PR** time only. `release.yml` *regenerates* this file
rather than verifying it, so drift can no longer fail an already-pushed tag —
a tagged build always displays the AetherEngine version it was actually linked
against. `pr-checks.yml` is the only place the checked-in constant is enforced,
which is why letting drift through there quietly rots it.

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

## Manual/automated UI verification

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
detail-page screens — real accessibility elements, real taps. **Confirmed
NOT working for the Player screen** (`PlayerView`/`PlayerControlsOverlay`):
`idb ui describe-all` returns an empty tree there (root node, zero children)
even with controls on screen, and coordinate taps aimed at any specific
control (close, captions, rotation-lock, transport buttons, the scrubber)
silently do nothing, while a generic full-screen tap still works. The
working theory is AetherEngine's constantly-updating video surface, not a
bug in the buttons themselves — a real device tap on the same buttons works
fine. Don't burn time retrying automated taps against the Player screen;
ask the user to verify interactive behavior there manually instead.

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

### Navigation (`Shared/Navigation/`)

Single shared `AppRoute` enum (`collection`, `assetDetail`) used as the
`navigationDestination(for:)` type across all three tabs in `MainTabView`
(Home/Search/Profile), each with its own `NavigationStack`. Adding a new
pushable destination means adding a case to `AppRoute` and a branch in
`AppRouteDestinationView`, not a per-feature navigation type.

### Models (`Core/Models/`)

Jellyfin API DTOs (`JellyfinModels.swift`) are kept separate from the app's
own lighter view-facing models (e.g. `MediaItem`, `MediaCollectionRail`) —
DTOs get mapped into app models (usually via an `init(dto:images:)`
initializer) rather than passed directly to views.

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
