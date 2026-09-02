<p align="center">
  <img src=".github/dionysus-iOS-Default-512x512@1x.png" alt="Dionysus Player" width="180">
</p>

<p align="center">
  <a href="https://github.com/imbenjamin/dionysus-player/releases"><img src="https://img.shields.io/github/v/release/imbenjamin/dionysus-player?include_prereleases&logo=github" alt="GitHub Releases"></a>
  <a href="https://testflight.apple.com/join/M6cu7Afs"><img src="https://img.shields.io/badge/TestFlight-Alpha%20Releases-blue?logo=appstore" alt="TestFlight Alpha Releases"></a>
</p>
<p align="center">
  <a href="https://github.com/imbenjamin/dionysus-player/actions?query=branch%3Adevelop"><img src="https://img.shields.io/github/check-suites/imbenjamin/dionysus-player/develop?logo=github&label=develop" alt="GitHub branch check suites"></a>
</p>

# Dionysus Player

A better and open Apple client for Jellyfin.

Dionysus Player is a native client for [Jellyfin](https://jellyfin.org) media
servers, targeting iOS/iPadOS first, with tvOS and macOS to follow. It talks
to your Jellyfin server over the [Jellyfin REST API](https://api.jellyfin.org/)
and plays media using [AetherEngine](https://github.com/superuser404notfound/AetherEngine),
an FFmpeg + VideoToolbox based playback engine with HDR10, HDR10+ and Dolby
Vision support.

The thing Dionysus is trying to do differently from other Jellyfin clients is
**offline downloads that actually feel like a commercial streaming app's** —
not a bolted-on "save for later" checkbox, but per-title quality control,
reliable background transfer, bulk season downloads, its own fully-offline
browsing UI, and local watch-progress that syncs back once you're
reconnected. See [Downloads](#downloads) below for what that covers today.

## Features

- **Browse & search** — home rails, library grids (Movies/Shows/Collections)
  with cascading genre/studio/decade/watched/favorite filters, search,
  cast & crew, "Up Next"/continue-watching.
- **Playback** — AetherEngine (FFmpeg + VideoToolbox), HDR10/HDR10+/Dolby
  Vision on supported source+device combinations, trickplay-thumbnail
  scrubbing, subtitle/audio track selection, intro/outro skip segments,
  Picture in Picture, Now Playing/lock-screen/Control Center integration,
  and a live "stats for nerds" overlay (codec, bitrate, resolution, dropped
  frames, streaming session info, offline-vs-live playback method).
- **Streaming** — defaults to **Allow Transcoding** (Settings → Playback):
  negotiates with the server via a real `DeviceProfile`, falling back to a
  server-chosen AVC or HEVC transcode with a configurable max-bitrate cap
  when direct play isn't possible, so a source your device can't decode
  still plays instead of failing outright. **Direct Play Always** (send the
  original file untouched, no negotiation) is also available for anyone
  who'd rather force it.
- **Downloads** — see below; this is the differentiator.
- **Accounts** — Jellyfin sign-in with silent session restore, per-server
  config, profile/settings screen.

### Downloads

- **Per-title and per-episode downloads**, plus bulk **season/whole-show**
  download and delete, from the same detail screens as live content.
- **Quality control**: a device-wide default (4K/1080p/720p/480p tier ×
  High/Normal/Data Saver preset) in Settings, or a **long-press on any
  download button** to override resolution/quality for that one download
  only — never upscales past the source, and picks the actual achieved
  bitrate rung rather than the requested one when a low-resolution source
  caps the output below what was asked for. The bitrate ladder is
  calibrated against what Disney+, Prime Video and Netflix actually ship,
  and the default tier is chosen per device class (720p on iPhone, 1080p on
  iPad) from the angular resolution each can actually resolve — see
  [DOWNLOADS.md](DOWNLOADS.md). Every Kbps value in that ladder can also be
  customized per device (Settings → Downloads → Advanced), with a one-tap
  reset back to the shipped default per value or for the whole ladder at
  once.
- **No pointless re-encoding**: a source that already fits the requested
  tier has its video track copied into the download untouched rather than
  re-encoded, avoiding a second generation of lossy compression.
- **Reliable background transfer**: real `URLSessionDownloadTask` background
  sessions (survive backgrounding, resume after relaunch), a configurable
  simultaneous-downloads limit, and HTTP-status validation on completion so
  a transcode error response can never masquerade as a successful download.
- **A fully offline app**: the Downloads tab, its own show/season grouping,
  and a local detail page work from a cold launch with zero network —
  metadata, artwork, cast/crew, and (where available) skip-segment data are
  all captured at download time, not fetched on demand.
- **Local watch-progress sync**: resume position and watched state update
  locally while offline and push back to the Jellyfin server automatically
  once the app is foregrounded with connectivity again.
- **Subtitle handling**: text-based subtitle tracks download alongside the
  video; image-based tracks (PGS/VobSub/DVB — Jellyfin has no server-side
  OCR to extract them as text, and MP4 can't embed bitmap subs) are skipped
  with an explicit warning up front rather than silently dropped.
- Storage lives under `Application Support` (not `Library/Caches`), so the
  OS never silently reclaims a title you explicitly chose to keep offline.

See `Core/Downloads`/`Features/Downloads` for the implementation, and
[Known limitations](#known-limitations) below for what this doesn't cover
yet.

## Status

Navigation, screens, and the networking/playback plumbing are in place with
placeholder content where noted. As of Xcode 26.5, the app builds clean end
to end — package resolution (AetherEngine and its dependencies), compilation,
and linking all succeed with no errors — and the unit test suite passes (see
[Testing](#testing)). Real device testing (see `TESTING.md`) has confirmed
direct-play HDR/Dolby Vision video with passthrough audio, the Downloads
feature end-to-end (queueing, background transfer, resume, bulk season
download, quality overrides, offline playback, sync-back), and Allow
Transcoding live streaming (both AVC and HEVC transcode targets, seeking,
Picture in Picture) — all driven by extensive live iPhone testing, not just
unit tests. Areas still resting on unit-test coverage alone rather than
confirmed live: non-Dolby-Vision HDR formats on other devices, and some
seeking/scrubbing edge cases.

## Known limitations

- **Downloads always come out HDR→SDR and AAC-LC stereo**, regardless of the
  source. The HDR loss is a hard limitation of Jellyfin's server-side
  transcoder (no HDR-to-HDR tone-mapping); the audio downmix is a deliberate
  v1 simplification. Live/direct-play is unaffected either way. See
  [DOWNLOADS.md](DOWNLOADS.md#limitations) for the full detail.
- **tvOS/macOS are not built yet** — iOS/iPadOS only for now, per the
  Status section above.
- **Audio/music libraries aren't supported yet** — browsing/playing music is
  future scope (see tvOS/macOS above), so a server's Music library and its
  contents (tracks, albums, artists, audio playlists) are suppressed
  throughout the app: hidden from Home's library rail and excluded
  server-side from Continue Watching/library grids, with a clear "not
  supported" state on the rare path that still reaches one (e.g. a
  "More Like This" rail, since Jellyfin's own `/Similar` endpoint can't be
  scoped by type) rather than the broken video-player attempt this used to
  cause. Every suppression site is marked `AUDIO SUPPRESSION:` in the code
  for easy removal/rewiring once real audio support lands.
- Rail/grid curation logic (what shows up on Home, in what order) is an
  explicit placeholder, not final UX.

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

## Testing

A `DionysusPlayerTests` unit test target covers the MVVM layer — ViewModels,
the Jellyfin networking client, models, and persistence — via a fake-server
pattern (`URLProtocol` stubbing) rather than hitting a real Jellyfin
instance. Run it from Xcode with the `DionysusPlayer` scheme (**Cmd+U**), or:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

All tests passing as of this writing. See [`TESTING.md`](TESTING.md) for the
full strategy, a coverage table, and known gaps (SwiftUI views, true
UI/end-to-end tests, and `AetherPlaybackEngine`'s own adapter code).

## Architecture

```
DionysusPlayer/
├── App/            Entry point, root app state machine
├── Core/
│   ├── Models/          Server config, credentials, domain models
│   ├── Networking/      Jellyfin REST API client & DTOs
│   ├── Playback/        Playback engine protocol + AetherEngine adapter
│   ├── Persistence/     Keychain-backed session storage, on-device search history
│   └── Downloads/       Offline downloads — SwiftData model, file store,
│                        download/sync managers (see below)
├── Features/
│   ├── ServerSetup/     One-time server address entry
│   ├── Login/           Jellyfin sign-in, remembers & auto-logs in
│   ├── Home/            Hero banner, library rail, and content rails
│   ├── Collection/      Grid of a library/collection's items
│   ├── AssetDetails/    Movie/Show detail — hero header, Play/Resume/Restart,
│   │                    tabbed About/Cast & Crew/Details area
│   ├── Player/          AetherEngine-backed playback UI (online and offline)
│   ├── Search/          Jellyfin search, results list
│   ├── Downloads/       Offline-downloaded content — list, per-show/season
│   │                    grouping, and a fully local detail page
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

## License

GPLv3 (see [LICENSE](LICENSE)), with an added App Store/DRM exception
under GPLv3 §7 permitting distribution through the Apple App Store and
similar platforms despite their code-signing and DRM restrictions —
source obligations are otherwise unaffected. [AetherEngine](https://github.com/superuser404notfound/AetherEngine),
the playback engine dependency, is separately licensed under
LGPL-3.0 with its own equivalent App Store/DRM exception.

See [PRIVACY.md](PRIVACY.md) for the app's privacy policy — also reachable
in-app from Profile.
