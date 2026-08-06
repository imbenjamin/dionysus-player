# Testing Strategy

This is a plain-language guide to how testing works in this repo, written for
someone who hasn't tested a Swift/Xcode project before. It covers the tools,
what's covered so far, and how to extend it.

## The tools, briefly

- **XCTest** is Apple's built-in test framework — it ships with Xcode, no
  package to install. A test is just a method starting with `test` inside a
  class that inherits from `XCTestCase`. You assert with functions like
  `XCTAssertEqual(a, b)` or `XCTAssertTrue(condition)`; a failed assertion
  fails that test and shows you the expected/actual values.
- **Unit tests** run in-process, no simulator UI, no real network — fast
  (the whole suite here runs in a few seconds). This repo has only unit
  tests right now.
- **UI tests** (`XCUITest`) drive the actual app in the Simulator, tapping
  buttons and reading the screen. None exist yet — see "Not covered" below.
- A **test target** is a separate build target (`DionysusPlayerTests`) that
  compiles test code and links against the app so it can `@testable import
  DionysusPlayer` — that `@testable` gives tests access to `internal`
  declarations, not just `public` ones, which matters since almost nothing
  in this codebase is marked `public`.

## Running the tests

Open `DionysusPlayer.xcodeproj` (regenerate first with `xcodegen generate` if
you've pulled changes to `project.yml`), select the `DionysusPlayer` scheme,
and press **Cmd+U**, or click the diamond next to any individual `test...`
method/class to run just that one. Xcode's Test navigator (Cmd+6) lists
everything and shows pass/fail per test.

From the CLI, once you have a Simulator runtime installed:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

(swap `iPhone 17` for whatever's in `xcrun simctl list devices available` on your machine.)

**Verified:** the full suite (205 tests) has been run for real via
`xcodebuild test` against the iOS 26.5 Simulator — all passing, 0 failures.
A few real issues were caught and fixed along the way, worth knowing about
if you extend this setup:

- `PRODUCT_NAME` is `Dionysus` (not `DionysusPlayer`), and Xcode derives the
  Swift module name from `PRODUCT_NAME` by default — so the module is
  `import Dionysus`, not `import DionysusPlayer`. XcodeGen's automatic
  host-application wiring for the test target also assumed the bundle name
  matched the target name, so `TEST_HOST`/`BUNDLE_LOADER` are now set
  explicitly in `project.yml` instead of left to inference.
- `URLSession`'s async `data(for:)` moves a request's body into
  `httpBodyStream` before handing it to a custom `URLProtocol`, so
  `request.httpBody` reads back `nil` there — `MockURLProtocol.swift`'s
  `URLRequest.capturedHTTPBody` drains whichever one is actually populated.
- `AppState`/`ServerSetupViewModel` build their own `JellyfinAPIClient`
  internally rather than taking one by injection, always on `URLSession
  .shared` — `URLProtocol.registerClass(MockURLProtocol.self)` intercepts
  that process-wide instead of per-session (see `AppStateTests`).
- A shared async-polling helper (`waitUntil`, used for debounced/detached
  work) has to be `@MainActor`-isolated to match its callers, or Swift 6
  flags the closure argument as an unsafe cross-actor send.

## What's covered

The suite focuses on the highest-value, cheapest-to-test layer: pure logic
and the networking client, mirroring the app's own MVVM structure
(`Core/` and `Features/*ViewModel.swift` in `project.yml`'s CLAUDE.md sense).

| Area | File | What it checks |
|---|---|---|
| `MediaItem` | `MediaItemTests.swift` | All the display logic — year ranges, durations, episode labels, rail titles/subtitles, resume/played/favorite fractions and flags, image URLs (including the logo Episode→Season→Series fallback and the Thumb image's real-nil-when-absent behavior that `LandscapeMediaCard`'s poster fallback depends on), `usesLandscapeRailTile`'s series/episode-vs-everything-else split, `technicalDetails` (container/codec/resolution/dynamic-range formatting, including the letterboxed-video-classifies-by-width case), `metadataBadges` (resolution/dynamic-range/audio-format/accessibility call-outs, including the Dolby Digital family's Atmos > DD+ > DD priority collapsing, TrueHD's exception to that, and the DTS-HD > DTS priority), and `cast`'s role-vs-job-title fallback and unique-id-per-credit guarantee (the same person can be credited more than once on one item, sharing an underlying id — using that id alone gave `CastCrewGridView`'s `ForEach` duplicate identifiers, seen as intermittent gaps/repeated cells while scrolling). This is the single highest-value target: pure computation, no I/O, and it's exactly the kind of thing that silently breaks when a DTO field changes. |
| `MediaCollectionRail` | `MediaCollectionRailTests.swift` | `usesLandscapeTiles`'s whole-rail-not-per-item decision — portrait only when every item is movie-like, landscape if any item is series/episode-like (so a rail mixing both, e.g. "Continue Watching", reads as one consistent tile shape instead of a jumble of two). |
| `DynamicRailCandidate` | `DynamicRailCandidateTests.swift` | `railTitle`'s formatting for all 4 (kind × category) combinations — "{Genre} Movies"/"{Genre} Shows" vs. "Movies from {Studio}"/"Shows from {Studio}". |
| `ImageURLBuilder` | `ImageURLBuilderTests.swift` | URL construction — query params, token inclusion, item vs. user image endpoints. |
| `ServerConfiguration.parse` | `ServerConfigurationTests.swift` | Parsing whatever a user types into server setup (bare host, host:port, full URL, garbage input). |
| `JellyfinAuthorization` | `JellyfinAuthorizationTests.swift` | The auth header format Jellyfin expects. |
| `JellyfinJSON` (coding) | `JellyfinCodingTests.swift` | PascalCase↔camelCase key conversion, and the date decoder's handling of Jellyfin/.NET's inconsistent fractional-second precision (including the 7-digit tick-precision case). |
| `JellyfinAPIClient` | `JellyfinAPIClientTests.swift` | Request construction (paths, query params, auth headers), response decoding, HTTP/decoding error handling, the `collectionsContaining` fan-out logic, `genres`/`studios` discovery requests, and `items(...)`'s `Genres`/`Studios` filters being pipe-delimited (unlike every other joined param on that method, which is comma-delimited) — all against a fake server (see below), not a real one. |
| `KeychainStore` | `KeychainStoreTests.swift` | Save/load/delete round-trips against the real Keychain (Simulator keychain access needs no special entitlement for this). |
| `ServerSessionStore` | `ServerSessionStoreTests.swift` | Persistence round-trips across fresh instances, and that `clearCredentials` vs. `clearAll` affect the right subset of state. |
| `SearchViewModel` | `SearchViewModelTests.swift` | Empty-query short-circuit, debounced search, error state. |
| `HomeViewModel` | `HomeViewModelTests.swift` | The multi-endpoint fan-out in `load()` — the hero rail's random-unwatched-movies-and-series query (`IncludeItemTypes`/`SortBy=Random`/`Filters=IsUnplayed`), the libraries rail straight from `/Users/{id}/Views`, rail ordering (Continue Watching, then Next Up, then Recently Added Movies/Shows), remaining rails omitted when empty, `seeAllQuery` wiring, and that `loadIfNeeded()` doesn't re-fetch once `loadState` is no longer `.idle` — including the case where every array legitimately loaded empty (a regression net for a guard that used to check `rails.isEmpty` instead, which would've kept re-fetching forever in that case). Also: dynamic genre/studio rails appended after the curated set with correctly formatted titles, deterministic ordering via an injectable `shuffle` closure (identity in tests, a real shuffle in production), `loadMoreDynamicRails()`'s batching (10 candidates per batch, `hasMoreDynamicRails` tracking exhaustion), a candidate below `minimumDynamicRailItemCount` (5) being dropped the same as a genuinely empty one, and `loadMoreDynamicRails()` no-opping rather than double-fetching when called while already loading. |
| `CollectionGridViewModel` | `CollectionGridViewModelTests.swift` | Query parameters (`parentID`/`includeItemTypes`/sort) reach the client correctly, error state, `loadIfNeeded()` short-circuit. |
| `AssetDetailViewModel` | `AssetDetailViewModelTests.swift` | The movie-vs-series branch in `load()` (only series fetch `Seasons`), `resolveSeriesPlaybackItemID()`'s fallback chain (next-up episode → first episode of first season → `nil` for non-series), and `preloadedItem` seeding `item` before any load plus still triggering the full fetch (`loadIfNeeded()`'s guard is on `loadState`, not `item`, precisely so a preloaded item doesn't look like "already loaded" and get skipped). |
| `AppState` | `AppStateTests.swift` | The `.serverSetup` → `.login` → `.main` phase machine: silent sign-in on launch (success and failure-falls-back-to-login), `completeServerSetup`/`signIn`/`signOut`/`changeServer` all affecting the right subset of state. |
| `LoginViewModel` | `LoginViewModelTests.swift` | `canSubmit` gating, delegation to `AppState.signIn`, the user-facing error message on failure. |
| `ServerSetupViewModel` | `ServerSetupViewModelTests.swift` | `testConnection()`'s address validation, server-name detection/fallback, and unreachable-server handling. |
| `PlayerViewModel` | `PlayerViewModelTests.swift` | Resume-position seeking (and the `startFromBeginning` override), playback-start/-stop reporting with correctly converted tick values, transport controls delegating to the engine, and engine→ViewModel state/time callbacks. Uses `FakePlaybackEngine` (Support/) rather than a real `AetherEngine`. |
| `PlaybackRequest` | `PlaybackRequestTests.swift` | `id`'s inclusion of `startFromBeginning`, so a Restart-after-Resume presents a fresh sheet. |
| `DeviceIdentity` | `DeviceIdentityTests.swift` | The generate-once-then-cache behavior of `deviceID`. |
| `JellyfinAPIError` | `JellyfinAPIErrorTests.swift` | Exact `errorDescription` text for each case, including the optional-message branch on `.http`. |
| `AppVersionInfo` | `AppVersionInfoTests.swift` | The build-version footer's text format and its fallback to "unknown" when the git branch/commit Info.plist keys are missing. |

### How network calls are faked

`JellyfinAPIClient` is a `actor` that owns a concrete `URLSession`, not a
protocol — so instead of a hand-written fake client, `Support/MockURLProtocol.swift`
provides a `URLProtocol` stub. You hand it a session
(`MockURLProtocol.makeSession()`), inject that into a real `JellyfinAPIClient`,
and script `MockURLProtocol.requestHandler` to return canned responses. This
means what's under test is the client's *actual* request-building and
decoding code, not a re-implementation of it — the same seam the real app
would use to point at a real server. The `ViewModel` tests reuse this same
pattern, since ViewModels are constructed with an already-built client
(per `CLAUDE.md`'s architecture notes), not a protocol either.

## What's *not* covered yet

- **SwiftUI views** — no view/snapshot tests. Views here are mostly thin
  (`body` wired to a ViewModel's published state), so the ROI is lower than
  the ViewModel layer underneath them; worth adding snapshot tests
  (e.g. via `swift-snapshot-testing`) once the UI stabilizes rather than
  before.
- **`AetherPlaybackEngine`** itself — still untestable in the traditional
  sense (it wraps a real `AetherEngine` instance, which needs real media and
  a real display to construct). `PlayerViewModel` — the thing that actually
  has logic worth pinning down — *is* now covered, via `FakePlaybackEngine`
  standing in for it. `AetherPlaybackEngine` does have a few pure `private
  static` helpers (`describe`, `normalize`, `displayTitle` — HDR format
  labels, track display-title fallback) that could be tested directly by
  dropping `private`, if that logic gets more involved than it is today.
- **End-to-end/UI tests** — nothing drives the app in the Simulator yet.
  Worth adding once the core flows (server setup → login → browse → play)
  are stable enough that a UI test isn't just recording a moving target.
- **`RootView`/`MainTabView`/navigation wiring** — `AppRoute` itself has no
  logic (just an enum), and the views that switch on `AppState.phase` are
  thin enough that a UI test would cover them more usefully than a unit test
  would.

## Adding a new test

1. Put it under `DionysusPlayerTests/`, mirroring the path of the file it
   tests (e.g. a test for `Features/Foo/FooViewModel.swift` goes in
   `DionysusPlayerTests/Features/Foo/FooViewModelTests.swift`).
2. New *files* need `xcodegen generate` re-run so Xcode picks them up
   (`sources:` in `project.yml` points at the whole `DionysusPlayerTests`
   folder, so no `project.yml` edit is needed — just the regenerate).
3. For anything that talks to `JellyfinAPIClient`, use the
   `MockURLProtocol` pattern above rather than hitting a real server.
4. Prefer testing ViewModels/models over views — that's where the logic
   actually lives in this codebase (see `CLAUDE.md`'s Architecture section).
