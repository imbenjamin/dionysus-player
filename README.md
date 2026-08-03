# Dionysus Player

A better and open Apple client for Jellyfin.

Dionysus Player is a native client for [Jellyfin](https://jellyfin.org) media
servers, targeting iOS/iPadOS first, with tvOS and macOS to follow. It talks
to your Jellyfin server over the [Jellyfin REST API](https://api.jellyfin.org/)
and plays media using [AetherEngine](https://github.com/superuser404notfound/AetherEngine),
an FFmpeg + VideoToolbox based playback engine with HDR10, HDR10+ and Dolby
Vision support.

## Status

This is an early skeleton: navigation, screens, and the networking/playback
plumbing are in place with placeholder content where noted, but it has not
yet been built or run — see [Building](#building) for why, and what to check
first.

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

> **Note:** This scaffold was written in an environment without a macOS/Xcode
> toolchain available, so it has **not** been compiled or run. When you first
> open it in Xcode, expect to fix minor issues — most likely the exact
> AetherEngine API surface in
> `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift` (method names/
> signatures were written against its published docs, not against the
> compiler). Everything else (SwiftUI views, the Jellyfin networking client)
> is written directly against Apple SDKs and the documented Jellyfin REST API,
> so it should need little to no adjustment.

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
│   ├── Home/            Top bar (Movies/Series/Collections) + content rails
│   ├── Collection/      Grid of a library/collection's items
│   ├── AssetDetails/    Movie detail & Show (seasons/episodes) detail
│   ├── Player/          AetherEngine-backed playback UI
│   ├── Search/          Jellyfin search, grid results
│   └── Profile/         Server/account settings
└── Shared/         Reusable components (poster cards, async images, nav)
```

The networking and playback layers are each behind a small protocol
(`JellyfinAPIClient` speaks plain REST/JSON; `PlaybackEngine` wraps
AetherEngine) so the concrete implementations can evolve — or be swapped for
previews/tests — without touching feature code.
