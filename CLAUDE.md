# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dionysus Player is a native iOS/iPadOS client for Jellyfin media servers (tvOS/macOS
planned later). It talks to a Jellyfin server over the plain REST/JSON API
(https://api.jellyfin.org/) and plays media via AetherEngine, a third-party
FFmpeg + VideoToolbox playback engine (HDR10/HDR10+/Dolby Vision support), pulled
in as a Swift Package.

**Status: builds clean, playback untested.** This was originally scaffolded
without a macOS/Xcode toolchain and expected to need fixes in
`AetherPlaybackEngine.swift`, but as of 2026-08-04 (Xcode 26.5, iOS 26.5
Simulator) `xcodebuild build` for the `DionysusPlayer` scheme succeeds
end-to-end — package resolution (AetherEngine + its FFmpegBuild/SMBClient/
LibDovi dependencies), compilation, and linking all complete with no errors,
and the `DionysusPlayerTests` suite (84 tests, see `TESTING.md`) passes.
That confirms the code compiles against AetherEngine's real API; it does
*not* confirm playback actually works — no test here plays real media or
exercises a real device's decoder, so treat `PlayerViewModel`/
`AetherPlaybackEngine` runtime behavior as unverified until manually tried
against a real Jellyfin server.

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
server info, auth, browsing/search, playback info, and progress reporting.
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
