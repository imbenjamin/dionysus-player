<p align="center">
  <img src=".github/dionysus-iOS-Default-512x512@1x.png" alt="Dionysus Player" width="180">
</p>

# Dionysus Player

A better and open Apple client for Jellyfin.

Dionysus Player is a native client for [Jellyfin](https://jellyfin.org) media
servers, targeting iOS/iPadOS first, with tvOS and macOS to follow. It talks
to your Jellyfin server over the [Jellyfin REST API](https://api.jellyfin.org/)
and plays media using [AetherEngine](https://github.com/superuser404notfound/AetherEngine),
an FFmpeg + VideoToolbox based playback engine with HDR10, HDR10+ and Dolby
Vision support.

## Status

Navigation, screens, and the networking/playback plumbing are in place with
placeholder content where noted. As of Xcode 26.5, the app builds clean end
to end — package resolution (AetherEngine and its dependencies), compilation,
and linking all succeed with no errors — and a 216-test unit test suite
passes (see [Testing](#testing)). That confirms the code compiles against
AetherEngine's real API and that the ViewModel/networking layer behaves as
intended; it does **not** confirm playback actually works — no test here
plays real media or exercises a real device's decoder, so treat runtime
playback behavior as unverified until tried against a real Jellyfin server.

## Requirements

- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Jellyfin server to point the app at

## Building

The Xcode project itself (`DionysusPlayer.xcodeproj`) is generated from
[`project.yml`](project.yml) rather than committed, so the project structure
stays a readable diff instead of an opaque `.pbxproj`. To build:

```sh
xcodegen generate
open DionysusPlayer.xcodeproj
```

Then let Xcode resolve Swift Package dependencies (AetherEngine) and build
the `DionysusPlayer` scheme.

> **Note:** This scaffold was originally written in an environment without a
> macOS/Xcode toolchain, with the expectation that `AetherPlaybackEngine.swift`
> would need fixes once built against AetherEngine's real API. That's no
> longer the case — the app has since been built successfully (Xcode 26.5)
> with no compiler errors anywhere, `AetherPlaybackEngine.swift` included.
> What *hasn't* been verified is playback at runtime (no test plays real
> media), so treat that specifically as unconfirmed until tried against a
> real server.

## Testing

A `DionysusPlayerTests` unit test target covers the MVVM layer — ViewModels,
the Jellyfin networking client, models, and persistence — via a fake-server
pattern (`URLProtocol` stubbing) rather than hitting a real Jellyfin
instance. Run it from Xcode with the `DionysusPlayer` scheme (**Cmd+U**), or:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

216/216 tests passing as of this writing. See [`TESTING.md`](TESTING.md) for
the full strategy, a coverage table, and known gaps (SwiftUI views, true
UI/end-to-end tests, and `AetherPlaybackEngine`'s own adapter code).

## Architecture

```
DionysusPlayer/
├── App/            Entry point, root app state machine
├── Core/
│   ├── Models/          Server config, credentials, domain models
│   ├── Networking/      Jellyfin REST API client & DTOs
│   ├── Playback/        Playback engine protocol + AetherEngine adapter
│   └── Persistence/     Keychain-backed session storage
├── Features/
│   ├── ServerSetup/     One-time server address entry
│   ├── Login/           Jellyfin sign-in, remembers & auto-logs in
│   ├── Home/            Hero banner, library rail, and content rails
│   ├── Collection/      Grid of a library/collection's items
│   ├── AssetDetails/    Movie/Show detail — hero header, Play/Resume/Restart,
│   │                    tabbed About/Cast & Crew/Details area
│   ├── Player/          AetherEngine-backed playback UI
│   ├── Search/          Jellyfin search, grid results
│   └── Profile/         Server/account settings, build version footer
└── Shared/         Reusable components (poster cards, async images, nav)
```

The networking and playback layers are each behind a small protocol
(`JellyfinAPIClient` speaks plain REST/JSON; `PlaybackEngine` wraps
AetherEngine) so the concrete implementations can evolve — or be swapped for
previews/tests — without touching feature code.
