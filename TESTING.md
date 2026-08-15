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

**Verified:** the full suite (419 tests) has been run for real via
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
| `MediaItem` | `MediaItemTests.swift` | All the display logic — year ranges, durations, episode labels, rail titles/subtitles, resume/played/favorite fractions and flags, image URLs (including the logo Episode→Season→Series fallback and the Thumb image's real-nil-when-absent behavior that `LandscapeMediaCard`'s poster fallback depends on), `usesLandscapeRailTile`'s series/episode-vs-everything-else split, `technicalDetails` (container/codec/resolution/dynamic-range formatting, including the letterboxed-video-classifies-by-width case), `tagline` (first non-empty entry of `BaseItemDto.taglines`, skipping leading empty ones, `nil` when absent — shown above the synopsis on the About tab), `mediaVersions`/`technicalDetails(forVersion:)` (the Details tab's version picker — empty for a single/no source, preferring a filename-derived edition name (e.g. "Extended Version") recovered by diffing a version's `MediaSourceInfo.name` against the canonical version's per Jellyfin's own multi-version naming convention, falling back to per-version resolution+dynamic-range labels when that relationship isn't found, disambiguating two versions that land on the same coarse label, and falling back further to the server's raw `MediaSourceInfo.name` then a generic placeholder when neither is available), `metadataBadges` (resolution/dynamic-range/audio-format/accessibility call-outs, including the Dolby Digital family's Atmos > DD+ > DD priority collapsing, TrueHD's exception to that, and the DTS-HD > DTS priority), `cast`'s role-vs-job-title fallback and unique-id-per-credit guarantee (the same person can be credited more than once on one item, sharing an underlying id — using that id alone gave `CastCrewGridView`'s `ForEach` duplicate identifiers, seen as intermittent gaps/repeated cells while scrolling), `libraryContentItemTypes`'s mapping from a library's `collectionType` to the item type(s) `LibraryRailView`'s card tap should restrict its grid to (Movies→Movie, Shows→Series, Collections→BoxSet, everything else/non-library items unrestricted), `studios` mapping `BaseItemDto`'s `NameGuidPair` array down to just the names, `decade` bucketing a production year to its start year (e.g. 2016→2010) for `CollectionGridView`'s Decade filter, `withOptimisticPlaybackPosition(seconds:duration:)` overwriting resume position/fraction while deliberately leaving `isPlayed` untouched (see `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)` below for why) and no-opping for a zero/negative duration, `playbackProgressIdentity` changing whenever those userData-derived fields do (and staying equal for identical userData) — the `.id()` key `PlayResumeButtonRow`'s call sites depend on to actually re-render on a resume-position/watched change (see that property's own doc comment: a plain `let item` input on a view that also owns `@State` had already silently stopped picking up new values once before in this codebase, in `DetailTabsView`, without a `.id()` like this one forcing a fresh identity), and `accessibilityDescription` (the `railTitle`/`railSubtitle` comma-join `PosterCard`/`LandscapeMediaCard`/`HeroRailCard` read out to VoiceOver as one element). This is the single highest-value target: pure computation, no I/O, and it's exactly the kind of thing that silently breaks when a DTO field changes. |
| `MediaCollectionRail` | `MediaCollectionRailTests.swift` | `usesLandscapeTiles`'s whole-rail-not-per-item decision — portrait only when every item is movie-like, landscape if any item is series/episode-like (so a rail mixing both, e.g. "Continue Watching", reads as one consistent tile shape instead of a jumble of two). |
| `DynamicRailCandidate` | `DynamicRailCandidateTests.swift` | `railTitle`'s formatting for all 4 cases — "{Genre} Movies"/"{Genre} Shows", "Movies from {Studio}"/"Shows from {Studio}", "Starring {Actor}", "Directed by {Director}". Also `seeAllQuery(moviesLibraryID:showsLibraryID:)`: genre/studio cases scope to the matching movies/shows library with the genre/studio preset, actor/director cases return `nil`, and a `nil` library ID doesn't suppress the query entirely (just its `parentID`). |
| `ImageURLBuilder` | `ImageURLBuilderTests.swift` | URL construction — query params, token inclusion, item vs. user image endpoints. |
| `RemoteImageLoader` | `RemoteImageLoaderTests.swift` | Retry-with-backoff on transient failures (transport errors and 5xx) up to a configurable attempt limit, giving up and throwing once exhausted, in-memory caching (a second request for the same URL never hits the network), and in-flight de-duplication (two concurrent requests for the same URL share one network call) — all against a fake server via `MockURLProtocol`, same as `JellyfinAPIClient`. |
| `ServerConfiguration.parse` | `ServerConfigurationTests.swift` | Parsing whatever a user types into server setup (bare host, host:port, full URL, garbage input). |
| `JellyfinAuthorization` | `JellyfinAuthorizationTests.swift` | The auth header format Jellyfin expects. |
| `JellyfinJSON` (coding) | `JellyfinCodingTests.swift` | PascalCase↔camelCase key conversion, and the date decoder's handling of Jellyfin/.NET's inconsistent fractional-second precision (including the 7-digit tick-precision case). |
| `JellyfinAPIClient` | `JellyfinAPIClientTests.swift` | Request construction (paths, query params, auth headers), response decoding, HTTP/decoding error handling, the `collectionsContaining` fan-out logic — including its capped concurrency, its per-collection membership check omitting `defaultFields`' heavier payload (`Fields` absent from that specific request), and one collection's membership check failing not failing the whole call — `genres`/`studios`/`persons` discovery requests, `items(...)`'s `Genres`/`Studios` filters being pipe-delimited vs. `Person`/`PersonTypes` being comma-delimited (neither matches `IncludeItemTypes`/`Filters`'s own delimiter, and they don't match each other either), `searchHints(...)`'s query construction against the dedicated `/Search/Hints` endpoint and result decoding, `playbackInfo(...)`/`reportPlaybackStart`/`reportPlaybackProgress`/`reportPlaybackStopped` including an explicit `mediaSourceID` in their request bodies (the version-picker's choice) when provided and omitting it when not, `setFavorite`/`setWatched` each `POST`ing to mark and `DELETE`ing to unmark against their respective `FavoriteItems`/`PlayedItems` paths, `currentSession(deviceID:)` filtering `/Sessions` by `DeviceId` and returning `nil` when no session matches, and `subtitleURL(itemID:mediaSourceID:streamIndex:codec:)` building an external subtitle stream's URL from scratch (deliberately not from `MediaStream.deliveryUrl`, which a real server only populates given a `DeviceProfile` this app doesn't send — confirmed live, see that method's doc comment) with the `ApiKey` query item appended only when signed in, and the file extension chosen to match the stream's own codec (ass/ssa/vtt, falling back to srt) — all against a fake server (see below), not a real one. |
| `KeychainStore` | `KeychainStoreTests.swift` | Save/load/delete round-trips against the real Keychain (Simulator keychain access needs no special entitlement for this). |
| `ServerSessionStore` | `ServerSessionStoreTests.swift` | Persistence round-trips across fresh instances, and that `clearCredentials` vs. `clearAll` affect the right subset of state. |
| `SearchHistoryStore` | `SearchHistoryStoreTests.swift` | Persistence round-trips across fresh instances, most-recent-first ordering, re-selecting an existing entry moving it to the front instead of duplicating, trimming to the max-entries cap, per-user scoping, and `remove`/`clear` only affecting the given entry/user. |
| `SearchViewModel` | `SearchViewModelTests.swift` | Empty-query short-circuit, debounced search, error state, results loaded straight from Jellyfin's `/Search/Hints` endpoint (the sole search data source — no separate full-`BaseItemDto` grid), history loaded on `init` and kept in sync by `recordSelection`/`removeFromHistory`/`clearHistory`, `imageURL(for:)` returning `nil` until `loadImagesIfNeeded()` has resolved an `ImageURLBuilder` and then reflecting the session's *current* access token (not one baked in earlier — see `SearchResult`). |
| `SearchResult` | `SearchResultTests.swift` | `SearchHint`→display mapping: subtitle text per item type (year for Movie/Series; for Episode, "S1:E4 · Series Name" combining both halves when present, falling back to whichever half is actually available — including omitting the "S1:E4" label entirely rather than half-filling it when only one of season/episode number is present — and "Collection" for BoxSet, so a collection result isn't mistaken for a regular title), `imageReference` extraction (Thumb preferred over Primary when both are present, falling back to Primary alone, `nil` when neither tag exists), and `imageURL(images:)` resolving that reference fresh against whichever `ImageURLBuilder` it's given — including the case that's the whole reason it's a reference and not a stored `URL`: the same `SearchResult` resolving to a *different* URL once the access token changes, so a history entry persisted under an old token doesn't 401/403 forever after a later re-login. |
| `HomeViewModel` | `HomeViewModelTests.swift` | The multi-endpoint fan-out in `load()` — the hero rail's random-unwatched-movies-and-series query (`IncludeItemTypes`/`SortBy=Random`/`Filters=IsUnplayed`), the libraries rail straight from `/Users/{id}/Views`, rail ordering (Continue Watching, then Next Up, then Recently Added Movies/Shows), remaining rails omitted when empty, `seeAllQuery` wiring — including Recently Added Movies/Shows presetting `initialSortField: .dateAdded`/`initialSortOrder: .descending` rather than the grid's own bare default — and that `loadIfNeeded()` doesn't re-fetch once `loadState` is no longer `.idle` — including the case where every array legitimately loaded empty (a regression net for a guard that used to check `rails.isEmpty` instead, which would've kept re-fetching forever in that case). Also: all four dynamic rail types (genres, studios, actors, directors) appended after the curated set with correctly formatted titles, sharing one shuffle pool rather than being ordered separately, deterministic ordering via an injectable `shuffle` closure (identity in tests, a real shuffle in production), `loadMoreDynamicRails()`'s batching (5 candidates per batch, `hasMoreDynamicRails` tracking exhaustion), a candidate below `minimumDynamicRailItemCount` (5) being dropped the same as a genuinely empty one, `loadMoreDynamicRails()` no-opping rather than double-fetching when called while already loading, and that genre/studio rails' `seeAllQuery` carries the right title/parentID/includeItemTypes/genre-or-studio preset while actor/director rails' stays `nil`. |
| `CollectionGridViewModel` | `CollectionGridViewModelTests.swift` | Query parameters (`parentID`/`includeItemTypes`) reach the client correctly, error state, `loadIfNeeded()` short-circuit, defaulting to `CollectionSortField.title`/`CollectionSortOrder.ascending` (`SortName`/`Ascending`) when `query` carries no presets, `init` seeding `sortField`/`sortOrder`/`selectedGenre`/`selectedStudio` from `query.initialSortField`/`initialSortOrder`/`initialGenre`/`initialStudio` when it does (and that preset sort actually reaches the request), `setSortField(...)`/`setSortOrder(...)` independently reloading with the right `sortBy`/`sortOrder` — including that flipping order doesn't change field and vice versa, and a non-Title field can go ascending too (not locked to descending) — re-selecting the already-current field/order not triggering a redundant request, `availableGenres`/`availableStudios`/`availableDecades` deriving distinct sorted option lists from the currently loaded `items` (decades newest-first) *and cascading*: selecting one facet narrows the *other two*'s option lists down to only values that still co-occur with it (e.g. selecting a genre hides studios/decades that no longer have a matching item), a facet's own selection never narrows its own list (picking a genre doesn't collapse the Genre list to just that one value), narrowing composes across multiple active facets at once, and clearing a filter (or `resetFilters()`) widens every list back out, `availableWatchStatuses`/`availableFavoriteStatuses` folding into the same cascade (watched/unwatched and favorite/non-favorite narrow and are narrowed by the other facets identically, despite being user-data-derived rather than metadata-derived), `filteredItems` narrowing by whichever of `setGenreFilter`/`setStudioFilter`/`setDecadeFilter`/`setWatchStatusFilter`/`setFavoriteStatusFilter` are active — combined with AND across facets, clearing a filter (`nil`) restoring those items, and a combination that matches nothing returning empty rather than erroring — `randomItem()` picking only from `filteredItems` and returning `nil` when nothing matches — and `hasActiveFilters`/`resetFilters` (false with none selected, true with any single one, and resetting clearing every filter and restoring the full list). |
| `AssetDetailViewModel` | `AssetDetailViewModelTests.swift` | The movie/series/season/episode branches in `load()` — only series/season/episode fetch `Seasons`; a Season swaps `item` to its parent Series' own DTO (a Season has no content of its own worth showing) while an Episode keeps `item` as itself, both resolving `seriesID`/`preselectedSeasonID` either way, and both ending up with a `seriesItem` too (the Show's own item — reused from `item` for Series/Season, its own extra fetch for Episode, since `item` there is the Episode, not the Show) — plus `refreshItem()` re-fetching `displayedItemID` (the Series, for a Season load, or a selected Episode — see `selectEpisode(_:)` below) rather than `itemID` afterward. `showPlaybackEpisode`'s resolution: NextUp's fallback chain (in-progress/next-up episode → first episode of first season, `nil` with no `seriesID`) for a Series tapped directly, versus always that season's own first episode (never NextUp) for a Season tapped directly — both re-resolved by `refreshItem()` too, since a playback session can change which episode is "next". `selectEpisode(_:)` swapping `item`/`displayedItemID` to a tapped episode row's full item in place, without touching `seriesID`/`seasons`. `toggleFavorite(itemID:currentlyFavorite:)`/`toggleWatched(itemID:currentlyWatched:)` — `POST`/`DELETE` chosen from the passed-in current status, then re-fetching that same id (retrying on `userDataCommitPollSchedule`, shared with `refreshItem()` below, until the server actually confirms the new value, since Jellyfin's write endpoints return before the userData change is queryable — the mocked server in these toggle tests always confirms on the first attempt, so that retry loop itself isn't separately exercised here) and patching *every* property currently holding it (`item`, `seriesItem`, a `seasons` entry, `showPlaybackEpisode`), since a Show-content page's favorite/watched menu can target any of the Show/Season/Episode independently, not just whatever `item` currently is. `refreshItem()` actually retrying past a first stale poll response before picking up a changed `playbackPositionTicks` — a live regression (resume a movie, scrub, exit quickly — the new position didn't show up on the detail page within the old, shorter poll window even though the server had it right) that's what `userDataCommitPollSchedule` itself, and its sharing between both methods, is for. `applyOptimisticPlaybackPosition(_:)` — patching whichever of `item`/`showPlaybackEpisode` matches the closed session's `itemID` immediately, leaving the other untouched, and no-opping entirely for a non-matching id — plus the critical interaction between it and `refreshItem()` that a first attempt at this fix missed and shipped broken: `refreshItem()`'s poll used to capture its "did this change?" baseline *after* the optimistic update had already moved `item`, so the poll's near-guaranteed-stale first attempt looked like "a change" and got adopted immediately, silently undoing the optimistic value. Two tests pin the real fix (`optimisticPlaybackTarget`/`optimisticPositionTolerance`): a stale attempt or two get ignored until the server actually catches up, and — if it never does within the whole poll window — the known-correct optimistic value is left in place rather than falling back to whatever stale data the last attempt saw. `preloadedItem` seeding `item` before any load plus still triggering the full fetch (`loadIfNeeded()`'s guard is on `loadState`, not `item`, precisely so a preloaded item doesn't look like "already loaded" and get skipped), and `preferredMediaSourceID(forPlayableItem:)`/`setPreferredMediaSourceID(_:forPlayableItem:)` — the version-choice prompt's remembered answer for a later Resume — round-tripping through `MediaVersionPreferenceStore` and keyed by the *playable* item id, not this view model's own `itemID` (a Show's Play button resolves to a specific episode, distinct from the Series itself). `load()`'s supplementary rails (`similar`/`collections`/`seasons`) each failing independently without flipping `loadState` to `.failed` — only the primary item fetch (and, for a Season load, the Series item it swaps to) still can. `track(_:)`/`cancelBackgroundWork()` — a favorite-toggle confirmation poll that's cancelled mid-flight stops itself (via its own `Task.isCancelled` check) well short of its full retry schedule, rather than the outer `Task` being marked cancelled while the loop runs to completion regardless. `refreshItem()` changing `episodeListRefreshToken` on every call — what `SeasonEpisodeList` depends on to re-fetch a just-played episode's own row (progress bar/watched state) after returning from the player, rather than that list sitting stale until a manual season-picker change. `advanceToNextEpisodeIfCompleted(playedEpisodeID:)` — the "Up Next" auto-advance feature (2026-08-13): once the just-played episode is confirmed `played` (its own dedicated poll, not the unrelated `displayedItemID` one — see that method's doc comment for why the latter can't answer this for Show-direct content), a different NextUp result swaps `item` to it via `selectEpisode(_:)`, from *either* entry point (a Series-direct page becomes Episode content the same way an Episode-content page advances to its own next episode — same code path, `isEpisodeContent` is purely `item?.kind == .episode`) — covering both, plus NextUp-empty (series finished) and never-confirmed-played both correctly leaving `item` alone, and a season-boundary crossing updating `preselectedSeasonID` (which `selectEpisode(_:)` now also keeps current, not just `item`/`displayedItemID`) for `ShowDetailView`'s season picker to follow. Live-confirmed against a real server for the Show-direct entry point (see that method's own doc comment). `collectionItems` — a BoxSet's own children, fetched by `ParentId` alongside `similar`/`collections` in `load()` (and confirmed *not* fetched for a Movie, since the fetch shares its `/Items` path with the unrelated BoxSets-probe request inside `collectionsContaining` — the tests assert on the `ParentId` query param specifically to keep the two apart), then re-fetched again at the end of `refreshItem()` so a movie played directly from `CollectionItemList`'s own play button (which never pushes into that movie's own detail page, so never runs *its* `refreshItem()`) still picks up its new watched/progress state once the player closes. |
| `AppState` | `AppStateTests.swift` | The `.serverSetup` → `.login` → `.main` phase machine: silent sign-in on launch (success and failure-falls-back-to-login), `completeServerSetup`/`signIn`/`signOut`/`changeServer` all affecting the right subset of state. |
| `LoginViewModel` | `LoginViewModelTests.swift` | `canSubmit` gating, delegation to `AppState.signIn`, the user-facing error message on failure. |
| `ServerSetupViewModel` | `ServerSetupViewModelTests.swift` | `testConnection()`'s address validation, server-name detection/fallback, and unreachable-server handling. |
| `PlayerViewModel` | `PlayerViewModelTests.swift` | Resume-position seeking (and the `startFromBeginning` override), playback-start/-stop reporting with correctly converted tick values, transport controls delegating to the engine, engine→ViewModel state/time callbacks, version selection (`requestedMediaSourceID` scoping the `/PlaybackInfo` request and selecting the matching source over `.first`, an unrecognized requested id falling back to the server's default rather than failing, and `activeMediaSourceID` — whichever source actually got resolved — being reported alongside the start/progress/stop session calls), `setZoomMode(_:)` delegating straight through to the engine, `stats` passing through the engine's diagnostics snapshot unchanged, `sourceVideoStream` being set from the resolved media source's own video stream (not just its first stream), `refreshServerVersion()`/`refreshStreamingSession()` — the Streaming section's server-version fetch-once-and-cache behavior, and the live `/Sessions` poll populating play method and (only while transcoding) live transcode parameters, leaving the last known value in place on a failed request — `externalSubtitleSources(from:client:)` mapping a resolved source's `isExternal == true` subtitle `MediaStream`s (Jellyfin sidecar files) onto `ExternalSubtitleSource`s passed into `engine.load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`, leaving embedded streams alone (they arrive through the demuxer already) and skipping a stream whose `deliveryUrl` can't resolve into a URL rather than failing the whole load — and `atmosAudioTrackIndices(from:)` deriving the audio-track-index hint set from `MediaStream.audioSpatialFormat == "DolbyAtmos"` (server-reported, not codec/title text-matched — see that field's own doc comment), excluding a non-Atmos audio stream and a non-audio stream carrying the same field, and — a real bug found live, 2026-08-14 — correcting Jellyfin's reported `index` for any `isExternal == true` streams preceding it in the same source, since those consume slots in Jellyfin's index sequence without existing in the physical container AetherEngine actually demuxes (confirmed on a real Saving Private Ryan source: one external subtitle at index 0 shifted every embedded audio stream's reported index one higher than AetherEngine's own numbering for the identical tracks). Uses `FakePlaybackEngine` (Support/) rather than a real `AetherEngine`. |
| `PlaybackRequest` | `PlaybackRequestTests.swift` | `id`'s inclusion of `startFromBeginning` and `mediaSourceID`, so a Restart-after-Resume or a different version picked on a second Play each present a fresh sheet. |
| `MediaVersionPreferenceStore` | `MediaVersionPreferenceStoreTests.swift` | Persistence round-trips across fresh instances, overwriting a previous choice for the same item, and per-user/per-item scoping — same shape as `SearchHistoryStore`'s tests. |
| `DeviceIdentity` | `DeviceIdentityTests.swift` | The generate-once-then-cache behavior of `deviceID`. |
| `JellyfinAPIError` | `JellyfinAPIErrorTests.swift` | Exact `errorDescription` text for each case, including the optional-message branch on `.http`. |
| `AppVersionInfo` | `AppVersionInfoTests.swift` | The build-version footer's text format and its fallback to "unknown" when the git branch/commit Info.plist keys are missing. |
| `DeviceTiltObserver` | `DeviceTiltObserverTests.swift` | `smoothed(current:sample:factor:)`, the hero-effect's exponential low-pass filter; `uprightRelativeY(_:)`, which remaps raw `gravity.y` so a phone held upright (not lying flat) reads as the effect's centered/neutral position, clamped so reclining well past flat can't overshoot the effect's range; `start()`/`stop()`/`warmUp()`'s guard-clause early-return behavior in the Simulator (no physical sensor there) leaving `isApplyingChange` `false` rather than hanging; and `acquire()`/`release()` (the reference-counted pair `HeroHeaderView` uses instead of calling `start()`/`stop()` directly, so a same-instant push-to-another-detail-page doesn't race a real stop into leaving the sensor dead) resolving rather than hanging or crashing across balanced/unbalanced/immediately-re-acquired call patterns — the reference count/grace-period bookkeeping itself is `private` and the actual race it fixes was confirmed live on a real device, so isn't independently re-verified here — the rest is a thin `CMMotionManager` wrapper (real sensor I/O, same "not unit-testable" reasoning as `DeviceIdentity`'s `UIDevice`/`UserDefaults` calls). |
| `BackdropLogoOverlay` | `BackdropLogoOverlayTests.swift` | `rotation(tiltX:tiltY:maxDegrees:)`, the device-tilt depth effect's angle/axis computation — zero tilt is zero angle, a single-axis tilt reaches `maxDegrees` at full magnitude and scales linearly below that, a combined diagonal tilt clamps to `maxDegrees` rather than the two components summing past it, and tilting right vs. tilting forward rotate around different (perpendicular) axes. Everything else about this view is rendering, not computation, and isn't covered (known gap, same as other SwiftUI views). |

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
  static` helpers (`describe`, `normalize`, `title(for:providedName:)`,
  `descriptiveName`, `metadataLabel`, `audioFormatLabel`, `channelsLabel`,
  `makeExternalSubtitleTrack` — HDR format labels, and the track picker's
  title/language/flag-line normalization, e.g. telling a muxer's bare "ENG
  (srt)" echo of the language apart from a genuinely descriptive name like
  "Director's Commentary" and, in the latter case, folding the language
  back into the metadata line so it isn't lost, plus (audio tracks only)
  a format badge ("DD"/"DD+"/"DTS"/...) derived from the track's codec — 
  including that FFmpeg's DTS decoder is registered as `"dca"`, not
  `"dts"` (confirmed live) — a separate additive "Atmos" flag rather than
  Atmos replacing the format (a Dolby Digital Plus/Atmos track is still
  "DD+" first — the first version of this got that backwards, confirmed
  live on a Saving Private Ryan source carrying both a TrueHD/Atmos and a
  DD+/Atmos track), sourced from `TrackInfo.isAtmos` (EAC3-only) OR'd with
  a `knownAtmosAudioTrackIndices` hint set the *ViewModel* layer derives
  from Jellyfin's own `MediaStream.audioSpatialFormat` and forwards at
  load time (deliberately not a text heuristic over the track's embedded
  name — see `PlayerViewModel.atmosAudioTrackIndices(from:)`, which *is*
  covered, and the `PlaybackEngine.load(url:externalSubtitles:
  knownAtmosAudioTrackIndices:)` doc comment for why AetherEngine alone
  can't detect TrueHD/Atmos), and channel layout
  ("Mono"/"Stereo"/"5.1"/"7.1"/...)) that could be tested directly by
  dropping `private`, if that logic gets more involved than it is today.
  Same untestable-without-a-real-engine story applies to
  `applyForcedSubtitleSelection`/`languageMatches`: right after a fresh
  `load()`, a "forced" subtitle track (`TrackInfo.isForced`, the
  container's own FORCED disposition — covers embedded and declared-
  external tracks alike, no title-text matching) auto-activates without
  waiting for an explicit pick; when more than one forced track exists,
  whichever matches the language AetherEngine resolved as the active audio
  track wins, else the first forced track in container order — confirmed
  live (2026-08-14) against a real "Captain Phillips" source (English
  Forced track alongside full subtitle tracks): the quick-controls panel
  showed "Subtitles / Forced" already selected the instant playback
  started, with no manual pick made.
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
