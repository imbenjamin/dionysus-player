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
and the `DionysusPlayerTests` suite (392 tests, see `TESTING.md`) passes.
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
`ImageURLBuilder` is deliberately *not* actor-isolated — it's a plain struct
snapshotted via `client.makeImageURLBuilder()` so SwiftUI views can build
image URLs synchronously without hopping through the actor on every render.

Playback today is direct-play only: `streamURL(itemID:mediaSourceID:container:)`
builds a static stream URL. `PlaybackInfoResponse`/`DeviceProfile`-based
transcode negotiation is not implemented yet — if asked to add transcoding,
this is the file to extend.

### Playback (`Core/Playback/`)

`PlaybackEngine` is a protocol wrapping AetherEngine so feature code never
depends on the third-party library directly — `AetherPlaybackEngine` is the
real adapter, `PreviewPlaybackEngine` (`#if DEBUG`-gated) is a fake used only
in SwiftUI previews. When changing playback behavior, change the protocol
and both conformers; `PlayerViewModel` should only ever talk to the
`PlaybackEngine` abstraction.

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
