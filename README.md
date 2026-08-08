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
and linking all succeed with no errors — and a 296-test unit test suite
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

304/304 tests passing as of this writing. See [`TESTING.md`](TESTING.md) for
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
│   └── Persistence/     Keychain-backed session storage, on-device search history
├── Features/
│   ├── ServerSetup/     One-time server address entry
│   ├── Login/           Jellyfin sign-in, remembers & auto-logs in
│   ├── Home/            Hero banner, library rail, and content rails
│   ├── Collection/      Grid of a library/collection's items
│   ├── AssetDetails/    Movie/Show detail — hero header, Play/Resume/Restart,
│   │                    tabbed About/Cast & Crew/Details area
│   ├── Player/          AetherEngine-backed playback UI
│   ├── Search/          Jellyfin search, results list
│   └── Profile/         Server/account settings, build version footer
└── Shared/         Reusable components (poster cards, async images, nav)
```

The networking and playback layers are each behind a small protocol
(`JellyfinAPIClient` speaks plain REST/JSON; `PlaybackEngine` wraps
AetherEngine) so the concrete implementations can evolve — or be swapped for
previews/tests — without touching feature code.

## Localization

The app's user-facing strings go through Apple's [String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
mechanism (`DionysusPlayer/Resources/Localizable.xcstrings`), the current
standard replacement for `.strings`/`.stringsdict` files. Only English is
populated so far — no other language is enabled yet — but the mechanism is
wired up:

- SwiftUI call sites (`Text("...")`, `Button("...")`, `.navigationTitle("...")`,
  etc.) use plain string literals, which Xcode auto-extracts into the
  catalog because of their `LocalizedStringKey` parameter type.
- ViewModel/model-layer strings (errors, curated rail titles, and similar
  non-SwiftUI text) use `String(localized: "...")` instead, since
  `LocalizedStringKey` is a SwiftUI-only convenience type.
- Server/user-supplied content (item titles, library names, cast names, ...)
  and industry-standard technical terms/formatted data (codec names, HDR
  formats, timecodes, "S1:E4"-style labels) are deliberately left as plain
  strings — see the doc comments at each such call site for the reasoning.

**The catalog only fills in from Xcode.app's own IDE build**, not from a
`xcodebuild` CLI build — extracting newly-added strings into
`Localizable.xcstrings` is an Xcode source-editor integration, not a step
the command-line build system runs. Open the project in Xcode and build once
(**Cmd+B**) to populate it. From there, a translation vendor consumes the
catalog via `Product ▸ Export Localizations…` (or
`xcodebuild -exportLocalizations -localizationPath <dir> -exportLanguage <lang>`)
to get an XLIFF file, and returns a translated one to import back in.
Adding a language later is a matter of adding it to the catalog's
`localizations` in Xcode and importing the vendor's translations — no code
changes.
