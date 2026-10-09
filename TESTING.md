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

That runs the `UnitTests` plan, which is the scheme's default. There are two
more, both UI (see "UI tests" below) — ask for one by name:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -testPlan UITests-Smoke \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

| Plan | Contents | Where it runs |
| --- | --- | --- |
| `UnitTests` | The whole `DionysusPlayerTests` target | Every PR, every release |
| `UITests-Smoke` | Seven journeys + the keychain-reset check | Every PR (`ui-smoke` job), on iPhone + iPad, latest iOS |
| `UITests-Full` | Every UI test | Nightly and on release tags, on iPhone + iPad, every supported iOS version |
| `TVUnitTests` | `DionysusTVTests`: the shared unit tests, run on tvOS | Every PR (`tvos-build` job, not yet required), Apple TV 4K (3rd generation) |
| `TVUITests-Smoke` | Seven Apple TV journeys: first launch to sign-in, Home, a detail page from Home and a library, Search, the player | Every PR (`tv-ui-smoke` job), Apple TV 4K (3rd generation), tvOS 27.0; also nightly on tvOS 26.5, as an allowed failure (see "Where they run in CI") |
| `TVUITests` | `DionysusTVUITests`: every Siri Remote journey for the Apple TV app | Nightly and on PRs into `stable`, Apple TV 4K (3rd generation), tvOS 27.0 |

### The tvOS unit tests

`DionysusTVTests` holds the Apple TV app's own tests (the player host's
surface policy and session lifecycle, in `DionysusTVTests/`), and also
compiles a subset of `DionysusPlayerTests` against the tvOS
build of the shared core: everything that tests `Core/`, `AppState` and the
shared view models, minus the Downloads code tvOS doesn't have. The list is
`project.yml`'s `includes` on that target. A test that exercises iOS-only
behaviour stays out of the list with a comment saying why; a test that only
partly touches Downloads wraps that part in `#if DOWNLOADS`, which only the
iOS targets define. Never change an assertion to make it pass on tvOS.

On tvOS the server configuration lives in the keychain every Apple TV user
shares, not in `UserDefaults`, so a shared test that saves a server must also
delete `server.configuration` with `scope: .allUsers` in its `tearDown`
(`ServerSessionStoreTests`, `AppStateTests`, `LoginViewModelTests`).
Otherwise one test's server leaks into the next on tvOS only.
`TVAppLaunchTests` checks what the app's own launch sets up, since the test
host runs `DionysusTVApp.init`. `TVSignInRouteTests` pins where choosing a
user on Who's Watching? leads: one press for a user without a password,
Quick Connect for anyone else when the server has it, a password otherwise.
`TVSidebarLayoutTests`, `TVSidebarModelTests` and `TVProfileIdentityTests`
pin the sidebar: the fold rule (counted after the Music suppression), each
library's icon from its content type, its library load (which, like Home's,
survives a rebuild cancelling the caller), and the Profile entry's offline
fallback to the stored account. `TVShellNavigationTests` pins where the shell
is: choosing a row, the Libraries row toggling in place, and which row focus
may land on (only the page's own while collapsed, the Libraries row standing
in for a folded library).
`TVSignOutTests` pins Profile's two ways out: Sign Out forgets the account in
use on this Apple TV and leaves the others remembered, while Switch User keeps
it.

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

`DionysusTVUITests` drives the Apple TV app with `XCUIRemote` against the
same in-process stub server and launch arguments as the iOS suite
(`TVUITestCase.launch`). Its selectors live under `A11yID.TV`, with the iOS
suite's rules: never select on a label, never tag a screen-root container.
Focus moves only by remote presses (`TVUITestCase.press`), so a journey
reads as the presses a person would make.

Focus settles asynchronously — after a press, and after data arrives — so
check it with `TVUITestCase.waitForFocus`, never a bare `hasFocus` read. A
failed wait attaches the element tree to the result bundle. Rails are lazy
stacks: only what is on screen is in the tree, so a journey reaches a later
rail by pressing down to it rather than querying for it.

`TVUITestCase.launch` skips the Welcome by default, as the iOS suite does;
`LaunchJourneyTests` passes `skipsWelcome: false` for the one journey that
checks it. `OnboardingJourneyTests` covers Find Your Server (a discovered
server; Enter Server Address revealing the field and becoming its heading;
Rescan after the scan listing the same servers once each) and Who's Watching?:
a passwordless user, Quick Connect (the stub approves on the first poll),
Use Password Instead (`quickConnectPending`) and a server with Quick Connect
off (`quickConnectDisabled`). They stop at the password field rather than
typing into it: `typeText` into a tvOS `SecureField` opens the system keyboard
and is unreliable, and the sign-in behind it is `LoginViewModelTests`' job.
The scan radar's motion is off under the harness, so its screenshots show the
still rings; check the motion by launching with `-UITestScenario slowScan`
and without `-UITestDisableAnimations`.

`SidebarJourneyTests` drives the shell by identifier (`A11yID.TV.Sidebar`).
The rail is collapsed beside Home, Search, Profile and a library, with each
page's content starting right of it. Left (from the top row or a lower one) and
Menu open it on the page's own row, Right returns and closes it, and Menu with
it open sends the app to the background. Choosing a row opens its page with
the rail collapsed and the first item focused. Profile sits above Home and
reads "Profile & Settings". The `manyLibraries` scenario (six video libraries
and a Music one) puts them under a Libraries row that starts open and closes and reopens on
Select; its
Documentaries library is empty, which pins focus going back to the rail when a
page has nothing to focus. The rail's width says whether it's open (under 100pt
collapsed, over 300pt open), and it's polled (`waitForExpanded`,
`waitForCollapsed` in `Support/TVShellJourney.swift`): an `NSPredicate` on
`frame` never matches. Profile's Change Server asks first, in a cover of the
app's own rather than a `.confirmationDialog`, whose buttons lose their
identifiers on tvOS.

`AccountSwitchingJourneyTests` also turns Follow Apple TV Users off on Profile
and relaunches without a reset (`launch(resetsState: false)`): still signed in,
with the toggle still off. The Simulator has one Apple TV user, so the journey
can't show the two keychains apart; `ServerSessionStoreTests`' tvOS-only
`moveSession` tests do that, and `SessionScopeSettingTests` pins the default
and where the setting is stored. The harness's reset puts the setting back and
clears the shared session, or one run's "off" would leak into every later test.

Select a User Every Relaunch: `SessionScopeSettingTests` pins
`WhoIsWatchingPolicy` (asked only with Follow off, the setting on, and more
than one remembered account; from 30 minutes away), and `AppStateTests`'
tvOS-only cases pin that such a launch reaches Who's Watching? with no request
and every account still remembered, that one account or the setting off signs
straight in, and the time-away rule with injected dates. The journey signs in
a second account (the stub now answers the guest's sign-in as the guest), turns
Follow off, sees the second toggle appear, and relaunches to Who's Watching?
with the last account used focused. The 30-minute return has no journey.

`AccountSwitchingJourneyTests` covers the fallback for tvOS's user switching:
after Profile's Switch User, the seeded account is on Who's Watching? as a
remembered one (`A11yID.TV.Onboarding.rememberedUser`), focused, and one press
returns to Home with no code. Holding Select and choosing Forget This Account
puts it back among the server's users, where it asks for a code again
(`quickConnectPending`, so the code stays on screen). The menu's row is found
with `descendants(matching: .any)`: it isn't a button to XCUITest. An account
the server refuses, or a server that can't be reached, is `LoginViewModelTests`'
and `AppStateTests`' job; the order of the lockups is `TVWhosWatchingLayoutTests`'.

`PlayerReturnJourneyTests` pins what leaving the player comes back to: the
page as it was, since the player is laid over it. Focus is on the tile played
(Home's second, a library's second, so a return to the first can't pass for
it), a tile two rows down a library is still on screen with the grid where it
was left, and Search keeps its query. A library's posters are UIKit views and
report `hasFocus` directly; the grid scrolls only as far as the focused row
needs, so its position is compared before and after rather than assumed.

`OnboardingJourneyTests`' `manyUsers` journey (six users) checks that Who's
Watching?'s row scrolls above five lockups: the first isn't cut off, and Other
is fully on screen once focused. `SidebarJourneyTests`' `librariesFailAtFirst`
journey (the stub's `/Views` answers 500 for five seconds) checks that
libraries which failed at launch load once the rail is used again.
`ServerSessionStoreTests`' two-user `moveSession` tests (tvOS only) pin that
turning Follow Apple TV Users either way merges into what the destination
keychain holds and never overwrites it.

`DetailJourneyTests` covers detail pages inside the shell: a tile opens one
beside the rail and Menu pops it back to the tile; Menu on the root page still
opens the rail; a More Like This chain six deep (past the keep-alive cap of
four live pages) unwinds one page at a time to the tile it started from; and
a detail page that fails to load (`failingDetail`, which answers 500 for
`movie-03`'s own item) shows Retry with focus on it, where Menu still pops.
It also pins the movie page's own behaviour: Down walks Cast & Crew, More Like
This and Details in turn, Select on Details opens the full list and Menu
closes it; and moving back up to the action row returns the page to where it
landed, with Down pressed the moment the page opens. `largeCast` gives a movie
ten people, so a journey can press Up from one far to the right of the action
row, where nothing sits directly above.
`noBackdrop` strips the backdrop from an item fetched on its own, so a journey
can check the poster shows beside the title, right of it and scrolling with
the header, and that a title with a backdrop shows none.
`TVDetailHeaderArtTests` pins which image is chosen for each kind.
Home opens on its hero, so `launchAtHome` waits for the hero's Play to take
focus; `launchAtHomeTile` (or `focusFirstRailTile` after any launch) moves down
to Continue Watching's first tile, where journeys that open a tile start.
`HomeJourneyTests` covers the hero (Play starts playback, Menu leaves the
player on the title's detail page with focus on Play, and Menu again returns
to the hero; More Info opens the detail page; Right from More Info turns the page and
wraps to the first item after the last, and Left from Play opens the rail; it doesn't move by
itself under the harness, which freezes ambient motion), See All (it opens a
grid and Menu returns to the See All tile, found by walking to the third
rail, since a lazy row builds its end only when reached), that Home has no
Libraries rail (the sidebar lists them), that rails keep arriving past
batches that find nothing (`thinDynamicRails`: a hundred people with no
titles and one genre with enough), and a Home that fails to load (`failingHome`: the hero's
random query answers 500) offering Retry. `TVHeroPagerTests` pins when the
hero's timer runs and how it pages; `TVHeroPlayTargetTests` pins that a series
in the hero plays its next episode.
Two helpers in `TVShellJourney` are the way to a detail page and to the
player: `openDetailFromFocusedTile` and `playFromFocusedTile`.
`PlayerReturnJourneyTests` now pins the return from a detail page: to a tile
that isn't the page's first, to one below the first screen of a lazy grid, and
to Search with its query intact.

`CollectionGridJourneyTests` covers a library's grid: its count, pills and six
columns, with Up from the grid landing on the filters and Sort right of them;
a tile opening its detail page and Menu returning to it; Sort reordering the
grid with focus back on its pill at once; a genre filter narrowing the grid,
focus back on the pill within a second (polled, since `waitForFocus` checks
once a second), and Reset appearing, clearing it in one press and handing
focus to the first pill; Menu closing an open list without opening the rail;
a title marked watched on its detail page showing as watched on the tile
beneath, with the grid where it was left; a title that leaves a grid filtered
by Watched once marked the other way, which hands focus to its neighbour (it
used to abort the app on a stale index path); and a library that fails to load
(`failingLibrary`: listing Movies answers 500) offering Retry with focus on
it. The stub remembers a watched change for the session (`watchedOverrides`),
so a list fetched afterwards reflects it. The system alphabet index can't be
driven from XCUITest (it needs a held scroll), so it is checked by hand;
`TVAlphabetIndexTests` pins the letter each title sits under and the index's titles and jump targets, and that the bar runs the grid's way, A→Z or Z→A, each letter jumping further down than the last.

`ShowDetailJourneyTests` covers a show's page: Play names the episode it
starts and keeps focus while that episode is resolved; Down from the actions
lands on the tab of the season on show, not the one nearest Play; focusing
another tab switches the episode rail with no Select, and Up from the episodes
returns to their season's tab; the format badges of the episode Play starts
show in the header; More Like This sits below the episodes and Details below
that, opening the full list and describing the episode Play starts; an
episode tile doesn't play but turns the page to that episode, with focus on
Play, the page back at its top and Details describing it (measured from Play's
position: the header gains the episode's name, which moves the title); a
Continue Watching episode on Home opens
its show on that episode; and a show with no episodes (`showWithoutEpisodes`)
has no Play button, a message for the rail, and focus on Watched, where Menu
still pops. `TVSeasonEpisodesModelTests` pins the
model behind the rail: a season is fetched once, an empty one isn't a failure,
a refresh that fails keeps what was on screen, and a fetch cancelled by
focus passing over its tab isn't a failure.

`TVShowArtTests` pins whose imagery a show's page draws (the episode, then the
season chosen, then the episode Play starts, then the show) and that an item with none of its own uses the
ancestor the server names. No journey checks it: the backdrop is hidden from
accessibility, and the stub's images are all the same placeholder.

`CollectionDetailJourneyTests` covers box sets and playlists: a box set opens
with focus on its first movie, each opens its own detail page and Menu unwinds
both; a playlist plays from Play and from a row; and an empty playlist (the
fixture's Late Night) shows a message that takes focus, so Menu pops. Under
`emptyBoxSet` an empty box set shows its message with focus on it, so Menu
pops. With `noBackdrop`, a box set and a playlist show their poster beside
the title. Under `slowBoxSet` (every request naming the box set held for 8s) the page's
loading indicator takes focus, so the sidebar stays shut and Menu pops
before anything has loaded, and focus moves to the first movie once it has.
`LoadingJourneyTests` does the same for Home and a library under `slowItems`
(every list of items held for 8s): the indicator holds focus past the
shell's three seconds, then the page's first item takes it.
`TVPosterCellTests` pins that a grid poster still loading, or without
artwork, is inset as loaded artwork is, and `MediaPlaceholderGlyphTests` the
tvOS placeholder glyph's scale.
`TVPlayerPresenterTests` pins that no second player is presented while one
is in the presented chain.

`PlayerJourneyTests` opens the player from a detail page's Play. Under the harness
the host gets the fake engine, so nothing is handed to AVKit; the journeys
check that the remote reaches the host's own handlers (Right skips 10s) and
that Menu dismisses, including while the item is still loading
(`slowPlaybackInfo`). `PlayerStatsJourneyTests` checks the stats icon is
absent while its setting is off (on by default in the debug builds tests run),
and that it toggles the playback stats panel, which shows the fake engine's
readings and stays through Menu and Select. `PlayerAccessibleTransportJourneyTests`
forces the accessible transport (`-UITestAccessibleTransport YES`, since
XCUITest can't run VoiceOver) and drives it with the real focus engine:
Play/Pause has focus as the player opens and relabels on a press, the
transport stays up while playing until Menu hides it, Select, Up and Down
each bring it back on Play/Pause while Left and Right skip and leave it
hidden, Up from the scrubber lands on Play/Pause even from the far right, Forward and the scrubber skip 10s (the
scrubber's spoken value changes with it), Audio opens the panel on the
chosen track and a second track is marked selected, Menu closes the panel,
then hides the controls, then the player, and Skip and Next Up's Close are buttons reached with Up
from the last icon. The scrubber's adjustable steps (VoiceOver's swipe up and
down) are checked by hand, since XCUITest reports it as Other.
`TVPlayerAccessibleTransportTests` pins the reducer in that mode: raw arrows,
Select and swipes do nothing, each `TVPlayerControl` reuses the remote's own
action, nothing fades or times out, and a stale panel row does nothing;
`TVAccessibleTransportTests` pins when the mode is on and what is announced. `TileShapeJourneyTests` reads a tile's shape from its
frame: a shows library's grid and Search's Shows rail are landscape, a movies
library's grid stays posters. `SearchJourneyTests` opens Search from the rail and
types into the system search field (`typeText` works on tvOS once the field
exists, delete keys included): a result sits under its type's rail and opens
its detail page with the query kept, a show is listed under Shows, an empty history shows iOS's
"Search Your Library" placeholder, a query
with no match says so, an opened result is listed under Recent Searches once
the field is emptied and Clear removes it, Search starts fresh after another
page is chosen, Search is full screen with the collapsed rail off the left edge, and
Menu slides the open sidebar in while Right sends it away again. idb's arrow keys don't reach the system keyboard; measure
it through XCUITest instead.

`ProfileJourneyTests` opens Profile from the rail: the brand pane names the
user, the server and both versions; every row is reachable with Down; Select
on an on/off row flips it (compared before and after, since "On" and "Off"
are localized); a setting with more choices opens a list of them with the
current one ticked and focused, where Select picks and returns to the row and
Menu leaves it unchanged; Advanced, Quick Connect approval and the License and
Privacy Policy pages open as covers that Menu closes back onto their row;
Streaming set to Direct Play Always drops the bitrate row; Quick Connect's row
is absent when the server has it off; and Sign Out asks first with Cancel
focused (Cancel returns to the row), then lands on Who's Watching? with the
account listed as an ordinary user, not a remembered one.

The tvOS `AccessibilityAuditTests` runs the iOS suite's structural audit types
over Home, a movie page, a show page, a library grid, Search with results,
Profile, Advanced, a settings picker, Quick Connect approval and a text page. Its suppressions
are the system keyboard's keys and the hit region of static text, since
nothing on tvOS is pointed at. It found that a page's
`.accessibilityHidden(false)` overrides every `.accessibilityHidden(true)`
inside it: `TVMainView` set it on the page on show, exposing the avatar and
the backdrops.

The transport journeys pin the player's own chrome: the title block sits
top-left, the elapsed time and scrubber are on screen, and the format chip is
not (it's hidden on tvOS until the engine labels HDR correctly). They
pass `-UITestDisableControlAutoHide YES` so the chrome can't fade mid-read.
The logo fallback is observed through the same DEBUG marker the iOS hero uses
(`A11yID.Media.heroLogoFallbackVisible`), because the title block's label is
set explicitly and so doesn't change when the text stands in for the logo;
`slowLogoImage` holds every logo past the journey.
Play/Pause is checked with auto-hide left on: the journey pauses, waits past
the fade and checks the transport is still up and the time hasn't moved. The
harness engine's `togglePlayPause()` used to do nothing, so any journey
pressing Play/Pause on either platform tested nothing until it was filled in.

The rail is held disabled at launch until Home claims focus, so focus goes
straight to the first tile when it arrives; every journey that starts from Home
depends on it.

The PR check that runs it, "tvOS build and unit tests", is deliberately not in
either branch ruleset yet. It joins them once it has been green on a run of
PRs; renaming it after that needs the rulesets updated in step.

**Verified:** the full suite has been run for real via
`xcodebuild test` against the iOS 26.5 Simulator — all passing, 0 failures.
The exact test count isn't tracked here — CI runs and logs it on every
push (see the "Build and Test" check), so a hand-maintained number in
this file only ever drifted out of date as tests were added.
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
| `MediaItem` | `MediaItemTests.swift` | All the display logic — year ranges, durations, episode labels (and `numberedEpisodeName`, the one "S1:E4 · Pilot" spelling for episode rows, poster subtitles and the toolbar menus, which used to join the two with a double space in some places), rail titles/subtitles, resume/played/favorite fractions and flags, image URLs (including the logo Episode→Season→Series fallback and the Thumb image's real-nil-when-absent behavior that `LandscapeMediaCard`'s poster fallback depends on), `usesLandscapeRailTile`'s series/episode-vs-everything-else split, `technicalDetails` (container/codec/resolution/dynamic-range formatting, including the letterboxed-video-classifies-by-width case), `tagline` (first non-empty entry of `BaseItemDto.taglines`, skipping leading empty ones, `nil` when absent — shown above the synopsis on the About tab), `mediaVersions`/`technicalDetails(forVersion:)` (the Details tab's version picker — empty for a single/no source, preferring a filename-derived edition name (e.g. "Extended Version") recovered by diffing a version's `MediaSourceInfo.name` against the canonical version's per Jellyfin's own multi-version naming convention, falling back to per-version resolution+dynamic-range labels when that relationship isn't found, disambiguating two versions that land on the same coarse label, and falling back further to the server's raw `MediaSourceInfo.name` then a generic placeholder when neither is available), `metadataBadges` (resolution/dynamic-range/audio-format/accessibility call-outs, including the Dolby Digital family's Atmos > DD+ > DD priority collapsing, TrueHD's exception to that, and the DTS-HD > DTS priority), `cast`'s role-vs-job-title fallback and unique-id-per-credit guarantee (the same person can be credited more than once on one item, sharing an underlying id — using that id alone gave `CastCrewGridView`'s `ForEach` duplicate identifiers, seen as intermittent gaps/repeated cells while scrolling), `libraryContentItemTypes`'s mapping from a library's `collectionType` to the item type(s) `LibraryRailView`'s card tap should restrict its grid to (Movies→Movie, Shows→Series, Collections→BoxSet, everything else/non-library items unrestricted), `studios` mapping `BaseItemDto`'s `NameGuidPair` array down to just the names, `decade` bucketing a production year to its start year (e.g. 2016→2010) for `CollectionGridView`'s Decade filter, `withOptimisticPlaybackPosition(seconds:duration:)` overwriting resume position/fraction while deliberately leaving `isPlayed` untouched (see `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)` below for why) and no-opping for a zero/negative duration, `withOptimisticFavoriteWatched(favorite:watched:)` overwriting only whichever of `isFavorite`/`isPlayed` is actually passed (leaving the other alone) and no-opping when neither is (see `AssetDetailViewModel.applyOptimisticFavoriteWatched(itemID:favorite:watched:)` below for why this one exists), `playbackProgressIdentity` changing whenever those userData-derived fields do (and staying equal for identical userData) — the `.id()` key `PlayResumeButtonRow`'s call sites depend on to actually re-render on a resume-position/watched change (see that property's own doc comment: a plain `let item` input on a view that also owns `@State` had already silently stopped picking up new values once before in this codebase, in `DetailTabsView`, without a `.id()` like this one forcing a fresh identity), and `accessibilityDescription` (the `railTitle`/`railSubtitle` comma-join `PosterCard`/`LandscapeMediaCard`/`HeroRailCard` read out to VoiceOver as one element). This is the single highest-value target: pure computation, no I/O, and it's exactly the kind of thing that silently breaks when a DTO field changes. |
| `MediaCollectionRail` | `MediaCollectionRailTests.swift` | `usesLandscapeTiles`'s whole-rail-not-per-item decision — portrait only when every item is movie-like, landscape if any item is series/episode-like (so a rail mixing both, e.g. "Continue Watching", reads as one consistent tile shape instead of a jumble of two). |
| `DynamicRailCandidate` | `DynamicRailCandidateTests.swift` | `railTitle`'s formatting for all 4 cases — "{Genre} Movies"/"{Genre} Shows", "Movies from {Studio}"/"Shows from {Studio}", "Starring {Actor}", "Directed by {Director}". Also `seeAllQuery(moviesLibraryID:showsLibraryID:)`: genre/studio cases scope to the matching movies/shows library with the genre/studio preset, actor/director cases return `nil`, and a `nil` library ID doesn't suppress the query entirely (just its `parentID`). |
| `ImageURLBuilder` | `ImageURLBuilderTests.swift` | URL construction — query params, token inclusion, item vs. user image endpoints, and `trickplayTileURL(itemID:width:sheetIndex:)` (no `MediaSourceId` path segment, confirmed live against a real server — see that method's doc comment). |
| `RemoteImageLoader` | `RemoteImageLoaderTests.swift` | Retry-with-backoff on transient failures (transport errors and 5xx) up to a configurable attempt limit, giving up and throwing once exhausted, in-memory caching (a second request for the same URL never hits the network), in-flight de-duplication (two concurrent requests for the same URL share one network call), and (2026-09-01) `image(for:maxAttempts:retryBaseDelay:)`'s per-call retry overrides — used by the hero backdrop/logo's extended patience budget — winning over the instance's own configured defaults — all against a fake server via `MockURLProtocol`, same as `JellyfinAPIClient`. |
| `TrickplayMath` / `TrickplayThumbnailProvider` | `TrickplayThumbnailProviderTests.swift` | The Player scrub-preview bubble's data source — Jellyfin's server-generated Trickplay tile sheets, not AetherEngine (its own cache-backed scrub stills turned out to only serve a narrow already-decoded window near the playhead, confirmed dead on a real device — see `TrickplayThumbnailProvider`'s doc comment). `TrickplayMath.frame(atSeconds:info:)`: the first thumbnail, a mid-sheet position, a sheet-boundary crossing, clamping past the track's declared `thumbnailCount`, and a degenerate `info` (any non-positive field) returning `nil` rather than dividing by zero. `TrickplayMath.sheetCount(for:)` — how many tile-sheet JPEGs an offline download needs to fetch up front (the live path never needs this, it fetches on demand): an exact multiple of `tileWidth × tileHeight` with no partial sheet, a single under-full sheet, and the same degenerate-`info` cases returning `0`. `TrickplayMath.bestInfo(from:mediaSourceID:preferredWidth:)`: no entry for the given (or a missing) `mediaSourceID`, an exact preferred-width match, falling back to the widest available when none meet the preferred width, and picking the smallest width that still clears it when several do. `TrickplayThumbnailProvider.thumbnail(atSeconds:)` against `MockURLProtocol`: the requested URL matches the sheet the math predicts, the returned `CGImage`'s dimensions match the tile size (i.e. it actually cropped one tile out of the sheet rather than returning the whole thing), and a request failure returns `nil`. |
| `OfflineTrickplayThumbnailProvider` | `OfflineTrickplayThumbnailProviderTests.swift` | The offline counterpart to the row above — same `TrickplayMath` seconds→tile math, but reading a sheet already written to `DownloadFileStore` (via `DownloadManager.enqueue`'s own best-effort trickplay fetch) instead of a network mock: a written sheet crops to the expected tile size, a sheet that was never successfully downloaded (a real download can fail per-sheet without failing the whole item) returns `nil` rather than throwing, and a degenerate `TrickplayInfo` returns `nil` the same way the live provider's math does. |
| `ServerConfiguration` | `ServerConfigurationTests.swift` | `parse(rawAddress:preferHTTPS:)`: whatever a user types into server setup (bare host, host:port, full URL, garbage input) — an explicit scheme in the typed address always wins over `preferHTTPS`. `explicitScheme(in:)`: the same "does this already have a scheme" check, exposed so `ServerSetupViewModel` can keep its HTTPS toggle honest rather than silently overriding it. `correctingScheme(usingLandedURL:)` (2026-08-27): rewrites just the scheme to wherever a connection test actually landed, leaving host/port/path untouched — see `ServerSetupViewModel`'s row below for why. |
| `JellyfinAuthorization` | `JellyfinAuthorizationTests.swift` | The `Authorization` header value (`MediaBrowser` scheme) Jellyfin expects. |
| `JellyfinJSON` (coding) | `JellyfinCodingTests.swift` | PascalCase↔camelCase key conversion, and the date decoder's handling of Jellyfin/.NET's inconsistent fractional-second precision (including the 7-digit tick-precision case). |
| `JellyfinAPIClient` | `JellyfinAPIClientTests.swift` | Request construction (paths, query params, auth headers), response decoding, HTTP/decoding error handling, the `collectionsContaining` fan-out logic — including its capped concurrency, its per-collection membership check omitting `defaultFields`' heavier payload (`Fields` absent from that specific request), and one collection's membership check failing not failing the whole call — `genres`/`studios`/`persons` discovery requests, `items(...)`'s `Genres`/`Studios` filters being pipe-delimited vs. `Person`/`PersonTypes` being comma-delimited (neither matches `IncludeItemTypes`/`Filters`'s own delimiter, and they don't match each other either), `searchHints(...)`'s query construction against the dedicated `/Search/Hints` endpoint and result decoding, `playbackInfo(...)`/`reportPlaybackStart`/`reportPlaybackProgress`/`reportPlaybackStopped` including an explicit `mediaSourceID` in their request bodies (the version-picker's choice) when provided and omitting it when not, `setFavorite`/`setWatched` each `POST`ing to mark and `DELETE`ing to unmark against their respective `FavoriteItems`/`PlayedItems` paths, `currentSession(deviceID:)` filtering `/Sessions` by `DeviceId` and returning `nil` when no session matches, and `subtitleURL(itemID:mediaSourceID:streamIndex:codec:)` building an external subtitle stream's URL from scratch (deliberately not from `MediaStream.deliveryUrl`, which a real server only populates given a `DeviceProfile` this app doesn't send — confirmed live, see that method's doc comment) with the `ApiKey` query item appended only when signed in, and the file extension chosen to match the stream's own codec (ass/ssa/vtt, falling back to srt). `MediaStream.deliveryMethod` decoding alongside `isExternal`, which answer different questions — where a stream lives in the library versus how it reaches the player for the route just negotiated. Then the attachment route behind authored-ASS fonts: `MediaSourceInfo` decoding a verbatim 10.11.11 `MediaAttachments` payload (and decoding fine without one, the overwhelmingly common case — 4 of 932 MKVs in the library this was built against carry any attachment at all), `attachmentURL(itemID:mediaSourceID:index:)` building `/Videos/{item}/{source}/Attachments/{index}` from ids with `ApiKey` only when signed in — from ids for the same reason `subtitleURL` is, since the server fills `MediaAttachment.deliveryUrl` only when the request carried a `DeviceProfile` — and `isFontAttachment(codec:mimeType:fileName:)` accepting each of its three signals *alone* (codec, MIME across both the `application/x-...` spellings and the registered `font/` tree, and filename extension including a CJK one), since no signal is reliable across containers and a missed font renders the script in a fallback face. Plus what it must reject: cover art, which is the common non-font attachment and would cost a download for bytes `CTFontManager` can only refuse, and WOFF, which is a font but not one `CTFontManagerRegisterFontsForURL` can register — the single veto rather than another signal, because a MIME type naming WOFF describes the bytes whatever the codec column says. `fontAttachments(in:)` keeps only the fonts, in container order — and `nextEpisode(currentEpisodeID:seriesID:seasonID:userID:)` (the in-player "Up Next" prompt's own lookup, distinct from `nextUp(...)` — see that method's doc comment for why) finding the following episode within the same season by `indexNumber`, crossing a season boundary to the next season's first episode when the current one is last in its own, and returning `nil` once there's no next season at all (the series has finished) — all against a fake server (see below), not a real one. Also, `sendRaw`'s `ConnectivityMonitor` reporting (2026-08-18, offline detection): a transport-level `URLError` reports `isOffline == true`, an HTTP error response (still a real reply from the server) leaves it `false`, and a subsequent successful call clears a prior failure — and `healthCheck()` hitting `GET /health` (Jellyfin's own purpose-built liveness endpoint, plain text not JSON) unauthenticated, used for the app's scenePhase-driven resume probe instead of re-fetching/decoding `publicSystemInfo()` just to prove reachability. A same-day follow-up (confirmed live on a physical device, offline at launch): `.shared`'s default 60s `timeoutIntervalForRequest` was found to make an unreachable-but-routable LAN server (e.g. on cellular with Wi-Fi off, rather than genuinely no network path at all) read as an indefinite hang rather than a prompt offline screen — not separately unit-tested (a real timer-based timeout isn't practical to pin without a fake clock), fixed by racing `sendRaw`'s actual request against a 20s `Task.sleep` rather than swapping in a session with a shorter timeout, which was tried first and reverted after it broke `MockURLProtocol` interception for every test that builds its `JellyfinAPIClient` internally — see `sendRaw`'s own doc comment. A later addition (2026-08-22, confirmed live against a heavily-shared public demo server that a session token can be invalidated server-side with no action by the app): a request that 401s while its `Authorization` header carries a `Token="…"` clause — `authenticate(...)`'s own 401 at first sign-in never does, so it's unaffected — silently re-authenticates with whatever credentials last succeeded via `authenticate(...)` and retries, up to `reauthBackoffSchedule`'s bound (0.5/1/2/4s delays before each retry after the first, which is immediate) before giving up as `.notAuthenticated`; no remembered credentials at all (nothing ever called `authenticate(...)` successfully on this client) fails fast as the same error without attempting a retry; and several requests 401ing around the same moment (e.g. `HomeViewModel.load()`'s fan-out) share one re-authentication rather than each racing to hit `/Users/AuthenticateByName` independently — `reauthenticate(using:attempt:)`'s in-flight-`Task` coalescing, asserted via three concurrent requests and one counted re-auth call. `AppStateTests` separately pins that `signOut()` forgets these remembered credentials on the (reused-across-sign-out) client, so a request still in flight around sign-out can't silently re-authenticate as the just-signed-out user. A same-branch addition (2026-08-27, Jellyfin 12.0 compatibility): the app now sends a single `Authorization: MediaBrowser …` header instead of the deprecated `X-Emby-Authorization`/`X-Emby-Token` pair — 12.0 disables those by default (`EnableLegacyAuthorization`), confirmed live against a real, public 12.0.0 instance (`demo.jellyfin.org/unstable`) both for the old scheme's hard rejection and the new one's success, and against a real 10.11.11 instance (`demo.jellyfin.org/stable`, matching this project's own LAN test server's version) to confirm the switch is backward compatible, not 12.0-exclusive. `lastResponseURL` (new, 2026-08-27): records whichever URL a response actually came back from, since `URLSession` follows redirects transparently — see `ServerSetupViewModel`'s row below for the bug this exists to fix. Also (2026-09-08, adding to playlists): `editablePlaylists(userID:)` — the "Add to Playlist" picker's destination list, structurally the same N+1 problem as `collectionsContaining` above (Jellyfin has no bulk "which playlists can I edit" query, and its own web client fans out one `getPlaylistUser` per playlist too) and carrying the same two protections: capped concurrency, and a fail-soft `try?` per check so one flaky permission response reads as "not editable" rather than failing the whole picker — plus dropping audio playlists before the fan-out even runs, and re-deriving the result from the browse order rather than the task group's completion order (which would otherwise shuffle the picker's rows between openings); only the initial browse can throw. `playlistUserPermissions` mapping a **403** to `nil` alongside its existing 404. `addItemsToPlaylist(playlistID:itemIDs:userID:)` POSTing comma-joined `ids` plus `userId`, with the same clean-403-to-`.notPermitted` remap `removePlaylistItems` uses. And `createPlaylist(name:itemIDs:userID:isPublic:)` seeding the new playlist's members in the same request (so there's no create-then-add window that could leave an empty playlist behind on a failure), asserted against the raw JSON body rather than a round-tripped struct for one field specifically: `IsPublic` must always be **present**, because Jellyfin's `CreatePlaylistDto.IsPublic` initializes to `true` server-side and a decode would happily supply a default for an absent key — omitting it would silently publish every playlist this app creates to every other user on the server. A same-day follow-up: each editable playlist now also comes back paired with what it already *holds* (`playlistMemberIDs(playlistID:)`, reading `GET /Playlists/{id}`'s bare-id `PlaylistDto` rather than the fully hydrated `/Items` list this call would immediately discard), so the picker can grey out a destination the target is already in — and that second lookup fails **open**, the opposite direction to the permission check beside it: a lost membership request costs the user a possible duplicate, never the ability to add at all, so the playlist stays listed with an empty member set rather than dropping out. Plus `episodes(seriesID:seasonID:userID:)` accepting a `nil` `seasonID` to return every episode in a series, which is how the picker learns what "add the whole show" actually covers. Quick Connect (2026-09-25): `Enabled` decoding a bare JSON boolean and sent without a token even when the client still holds a previous session's; `Initiate` carrying the `Client`/`Device`/`DeviceId`/`Version` header fields the server builds the session from (it throws without them) and no token; `Connect` sending the secret as a query item and leaving an unknown secret as a raw `.http(404)`, which is how expiry is read; `AuthenticateWithQuickConnect` posting `{"Secret": …}` and storing the token; `/Users/Me` sent with the token. And a 401 after a Quick Connect sign-in failing as `.notAuthenticated` without replaying an earlier password sign-in on the same client, which would silently swap users. |
| `ConnectivityMonitor` | `ConnectivityMonitorTests.swift` | `reportFailure()`/`reportSuccess()` flipping `isOffline`, and `URLError.indicatesOffline` classifying the transport-failure codes `JellyfinAPIClient.sendRaw` matches against as `true` while `.cancelled` (an abandoned request, not an outage) stays `false`. |
| `LibraryAvailability` | `LibraryAvailabilityTests.swift` | (2026-08-29) `update(_:)` changing `state` and no-opping when unchanged (same `@Observable`-singleton reasoning as `ConnectivityMonitor`), `retryAction` invoking whatever closure was set (`HomeView` wires this to its own `HomeViewModel.load()` once one exists — see `HomeViewModel`'s row below), and `reset()` restoring both to their defaults. `SearchView`'s landing page (before any query is typed, so it has no network activity of its own to fail) reads `state` directly instead of duplicating Home's own retry/reconnect handling — not separately unit-tested (no view tests, per "What's *not* covered yet" below), but `HomeViewModelTests` pins that `load()`/`retryLoadIfNeeded()` keep this mirrored correctly, including that the backoff loop's flicker-suppression (see `HomeViewModel`'s row) never leaves it stuck at `.unavailable` after an eventual success. |
| `DownloadResolution`/`DownloadBitratePreset`/`DownloadTranscodeCalculator` | `DownloadTypesTests.swift` | The offline-downloads bitrate/resolution ladder table (4K/1080p/480p × High/Normal/Data Saver, video and audio bitrates) and `DownloadTranscodeCalculator.target(...)`'s capping rule — never exceeding the source's own resolution/bitrate when it's below the requested tier, falling back to the tier's own max when source metadata is missing, and `main10` vs. `main` `VideoProfile` selection based on `isSourceHDR`. Also that the bitrate itself is looked up from the *achieved* tier, not the requested one — a real bug fixed live (2026-08-19, "Pokemon"): a 480p-only source with 1080p requested correctly capped dimensions down to 480p but kept using 1080p's own bitrate rung, since `min(..., sourceBitrate)` alone doesn't catch a source whose own bitrate happens to sit above the requested tier's rung; a source falling between two named tiers (e.g. 720p) now rounds *up* to the smallest tier that still contains it (1080p) rather than clipping to a smaller one. Also `DownloadBitratePreset.displayName(in:)`'s whole-number-vs-fractional Mbps formatting for `DownloadsSettingsView`'s quality picker. Also (2026-09-02, customizable ladder): `target(...)`/`estimatedTotalBytes(...)`'s injectable `videoBitrateLadder` closure defaults to the shipped table when omitted (every test above passes none, so they keep exercising the real default), a supplied closure's return value is used instead, and it's looked up from the achieved tier, not the requested one, exactly like the default path; and `displayName(bitrate:)`/`accessibilityDisplayName(bitrate:)` — the overloads that take an already-resolved bitrate rather than deriving one from `DownloadResolution.videoBitrate(preset:)` — render identically to `displayName(in:)`/`accessibilityDisplayName(in:)` for that same default bitrate, and correctly for a bitrate that isn't on the shipped ladder at all. |
| `DownloadQualityLadderStore` | `DownloadQualityLadderStoreTests.swift` | (2026-09-02) Per-device overrides to the bitrate ladder, editable from Downloads → Advanced (`DownloadsQualityLadderView`, whose toolbar carries a single whole-page "Reset All" action rather than a per-section one, since the setting spans all four resolution sections at once). A fresh store's `kbps(resolution:preset:)`/`videoBitrate(resolution:preset:)` fall through to `DownloadResolution.videoBitrate(preset:)`'s own shipped default (converted to/from Kbps) with `hasAnyOverride`/`isOverridden(resolution:preset:)` both `false`; `setOverride(_:resolution:preset:)` is reflected in both accessors, is visible to a second store instance constructed over the same `UserDefaults` (the mechanism that lets `DownloadsQualityLadderView`, `JellyfinAPIClient`, and `DownloadManager` each build their own store and stay in agreement with no shared reference — same shape as `DownloadPreferencesStore`'s own tests), and never perturbs any other of the twelve (resolution × preset) cells; values are clamped to `minKbps...maxKbps` rather than accepting a zero/negative/absurdly large fat-finger; `setOverride(nil, ...)` clears one cell back to its default, and `resetAll()` clears every cell in one call. Also: `setOverride(_:...)` with a (post-clamp) value that exactly equals that cell's own shipped default clears the override rather than persisting a redundant one — a real bug, found live: `DownloadsQualityLadderView` rebuilds each row's `TextField` binding fresh on every render, and SwiftUI can resync a freshly rebuilt binding by writing its currently-displayed value straight back through the new `set`, which without this rule could silently re-persist a just-cleared (or never-touched) cell as an "override" identical to its own default and show a reset affordance with nothing left to reset — covered both for a value that was never overridden and for a real override changed back down to the default. |
| `DownloadPreferencesStore` | `DownloadPreferencesStoreTests.swift` | Falls back to documented defaults (`.hd1080p`/`.normal`/`wifiOnly == true`/`maxConcurrentDownloads == 3`) on a fresh store; reads whatever `DownloadsSettingsView`'s `@AppStorage` pickers/slider wrote to the *same* `UserDefaults` keys (the mechanism that lets `DownloadManager`, non-view code, see a live Settings change with no shared object reference); an unrecognized stored raw value falls back to the default rather than crashing; `maxConcurrentDownloads`'s `0`-means-Unlimited sentinel mapping to `nil`. |
| `JellyfinAPIClient` (downloads) | `JellyfinAPIClientTests.swift` | `isImageBasedSubtitleCodec(_:)` recognizing every bitmap subtitle codec (PGS/VobSub/DVB, case-insensitively) and rejecting text formats/`nil`; `downloadStreamURL(...)` always requesting `Static=false`/`Container=mp4`/`VideoCodec=hevc`/`AudioCodec=aac`/`MaxAudioChannels=2`, capping resolution/bitrate to the source when it's smaller, capping to the tier when the source is larger, and setting `VideoProfile=main10` only for an HDR source; `updateUserData(...)` posting position/played/percentage to `/Users/{userId}/Items/{itemId}/UserData` — the offline sync path, distinct from the session-scoped `reportPlaybackProgress`/`Stopped` above. |
| `DownloadFileStore` | `DownloadFileStoreTests.swift` | Relative-path construction (video/subtitle/trickplay-tile per-item, image content-addressed by `sourceItemID`-`imageType`-`tag` rather than by which download references it — the shared-artwork dedup's storage layout) and its filename sanitization of non-alphanumeric characters; `write`/`moveFile` actually landing bytes at the expected path; `imageAlreadyExists` — the fetch-time half of the dedup — false before a write, true after; `fontRelativePath(itemID:index:fileName:)` keying a container's font attachment by its own attachment index (unique within a source, so two identically-named faces can't collide) and surviving a non-ASCII filename, which a CJK-subtitled release ships; `deleteItemFiles` removing an item's video, subs and fonts unconditionally — fonts live under `<itemID>/` precisely so the existing sweep takes them; `deleteImageIfUnreferenced` — the delete-time half — leaving a shared image file in place while another `DownloadedItem` row still points at it and freeing it once nothing does (including tolerating a `nil` path as a no-op); `fileSize(forRelativePath:)` — ground truth for `DownloadedAssetDetailView`'s on-disk size readout — matching the real bytes written and `nil` for a missing file. Runs against the real `Application Support` directory (not a temp/mock one — this type hardcodes its root, per its own doc comment on why `Caches` was rejected), so every test cleans up the files/itemIDs it touches in `tearDown`. |
| `DownloadStore` | `DownloadStoreTests.swift` | Insert/fetch/delete round-trips against an in-memory SwiftData `ModelContainer`; `visibleItems()` excluding `markedForDeletion` rows while `allItems()`/`pendingSyncItems()` still see them (a `markedForDeletion` row's whole remaining purpose is carrying a pending sync write — see the offline-downloads plan's "Delete semantics" section); `isImagePathReferenced(_:excludingItemID:)` — the shared-artwork dedup's reference check — true when another (even `markedForDeletion`) row shares the path, false when only the excluded row does, and checked across all four image fields (poster/backdrop/logo/thumb). |
| `DownloadedItem` | `DownloadedItemTests.swift` | `estimatedTotalBytes` — the bitrate/runtime-based size estimate `DownloadManager` substitutes as the progress total when the transfer itself never reports one (Jellyfin's live-transcode stream never sends a `Content-Length`) — matches the `(videoBitrate + audioBitrate) * durationSeconds / 8` math exactly against the bitrate ladder's own real numbers, and `nil` when runtime or bitrate is missing/zero (nothing to estimate from). `numberedEpisodeTitle` spells an episode as `MediaItem.numberedEpisodeName` does ("S1:E4 · Pilot"), or the title alone without a label. |
| `DownloadManager` (delete, concurrency queue) | `DownloadManagerTests.swift` | `delete(itemID:)`'s own logic against a real `DownloadFileStore` (cleaned up in `tearDown`) and an in-memory `DownloadStore` — deliberately *not* the background `URLSessionDownloadTask`/`AppDelegate` relaunch wiring, see "What's *not* covered yet" below. Without a pending sync write, delete removes the row and its files together; *with* one, the files are freed but the row survives (`markedForDeletion == true`) and is excluded from `visibleItems()` while still showing up in `pendingSyncItems()`. Shared-image dedup on delete: a logo two episodes both reference survives deleting one of them and is only actually freed once the last reference is deleted. Also the simultaneous-downloads limit (`DownloadPreferencesStore.maxConcurrentDownloads`, injected via `DownloadManager.init(preferences:)`): `queueVideoDownload` admits immediately under the limit, further items past it stay `.queued` and are admitted strictly in the order they were queued as slots free up (`test_simulateDownloadFinished`, the `#if DEBUG` test seam pairing with `startVideoDownloadOverride` to verify this without a real network call/background session), `0` (Unlimited) admits every item at once, a `.queued` row left over from a previous launch is picked back up by `resumePendingQueue()` (called from `init`, oldest `createdAt` first) rather than stuck forever, and deleting a still-`.queued` item drops it from the pending queue too. Also `delete(itemID:)` cancelling an actually in-flight transfer (via the same `cancelVideoDownloadOverride` DI seam `startVideoDownloadOverride` uses) — originally a real bug found live (2026-08-20, "Rushmore"): deleting a `.downloading` row used to only drop this manager's own delegate reference, leaving the real background `URLSessionDownloadTask` running orphaned under `com.dionysus.downloads.<itemID>`, so a same-day re-download reused an identifier the OS still considered live and its brand-new session's task was cancelled almost instantly (`NSURLErrorCancelled`, -999). That *class* of bug is gone since identifiers stopped being per-item (2026-09-06, see DOWNLOADS.md's "A background session per download exhausted the transfer service"), but a deleted row's transfer must still actually stop; a still-`.queued`, never-actually-started row correctly triggers no cancel at all. Also `makeBackgroundConfiguration()` — a pure function, tested directly with no real `URLSession` — asserting the app uses exactly **one** background session identifier rather than one per item (the -997 regression test) and that `waitsForConnectivity` is always on; the Wi-Fi Only gate moved onto the request, so `makeFetchRequest(url:allowsCellularAccess:)` is what now asserts `DownloadPreferencesStore.wifiOnly` reaches the transfer — including `allowsExpensiveNetworkAccess`, which excludes a personal hotspot the configuration-level flag never did. Also the automatic re-arm of transient transport failures: -997/-996/`.networkConnectionLost`/`.timedOut` re-queue the row (keeping `pendingDownloadURLString`, so none of `enqueue`'s artwork/subtitle/trickplay prep re-runs) and free the concurrency slot for the next item immediately, `NSURLErrorCancelled` fails straight away without retrying, deleting during the backoff cancels the scheduled retry, and an exhausted budget lands `.failed` with written wording rather than iOS's own "Lost connection to the background transfer service" string. Also that one completion frees exactly one slot even when a task reports both `didFinishDownloadingTo` and `didCompleteWithError`. Also `pendingOrActiveDownloadsCount` (2026-09-02) — the number `MainTabView`'s Downloads tab `.badge(_:)` reads: counts `.queued`/`.downloading` rows, excludes `.completed`/`.failed` ones and (matching `visibleItems()`) a row kept alive only as `markedForDeletion`. Not covered here: `downloadFontAttachments` (the enqueue-time fetch of a container's font attachments), which sits inside `enqueue`'s network-heavy internals this file deliberately stays out of. Its two decisions are each tested where they live — which attachments count, in `JellyfinAPIClientTests`' `isFontAttachment`/`fontAttachments(in:)`, and where the bytes land, in `DownloadFileStoreTests`' `fontRelativePath` — and the fetch itself is the same shape as `downloadSubtitles` beside it, down to the explicit HTTP-status check that keeps a 404 body off disk. |
| `DownloadsViewModel` | `DownloadsViewModelTests.swift` | Row grouping (multiple episodes of the same series collapse into one `.show` row); bulk selection — `beginSelecting`/`cancelSelecting` resetting the selection, `toggleSelection` adding then removing, `toggleSelectAll`/`isAllSelected` toggling between everything and nothing selected (and reading `false` when only some rows are picked); `selectedAssetCount` — the delete confirmation's "X total assets" figure — counting a selected show row as its real episode count, not 1, alongside any selected standalone items; `deleteSelected` actually removing every episode of a selected show (not just its group row), leaving unselected items untouched, and exiting selection mode afterward. Also that `rows` follows `DownloadStore` saves made elsewhere with no second `refresh()` — a status change and a newly inserted row both land. A real bug (2026-09-28): rows snapshot their status, and with only an on-appear refresh a download that finished while the tab was open sat on "Preparing download…" until the user left the tab and came back. |
| `DownloadsRowCaption` | `DownloadsRowCaptionTests.swift` | The Downloads list row's secondary line: the parts, then the on-disk size, joined with " · "; VoiceOver's version uses each part's spoken form ("1 hour, 32 minutes", "54.2 megabytes") comma-joined; a missing or zero size is left out rather than shown as "0 B"; and nothing at all to show yields no line. |
| `PlayerViewModel` (offline) | `PlayerViewModelOfflineTests.swift` | Split out from `PlayerViewModelTests.swift` (already large): the `init(downloadedItem:downloadStore:...)` branch of `start()`. Loads a local `file://` URL built from the stored `videoFilePath` (not `client.streamURL`), builds `ExternalSubtitleSource`s from the stored `subtitleFiles` (local paths, not `client.subtitleURL`), seeks to the stored `resumePositionTicks` unless `startFromBeginning`, seeds `mediaSegments` from the stored `DownloadedSegment` snapshot rather than fetching `/MediaSegments`, stages Now Playing info from the stored title, and — the one thing this path must never do — makes no network call at all (asserted directly, and enforced as a hard failure in every other test in this file via a request handler that throws). `stop()`'s offline branch (`writeOfflineProgress`): writes `resumePositionTicks`/`playedPercentage` and sets `pendingSync = true` on the `DownloadedItem` row directly rather than calling `reportPlaybackStopped`, and the 90%-played threshold that marks the item watched (clearing resume position, since there's no server to defer that judgement call to the way the live path does). Also (2026-08-20): `supportsScrubThumbnails`/`scrubThumbnail(atSeconds:)` staying unsupported when `DownloadedItem.trickplayInfo` is `nil`, and reading a real cropped tile off `DownloadFileStore` (via `OfflineTrickplayThumbnailProvider`) once it's set; `isOfflinePlayback` reading `true` for a downloaded-item session; and `refreshServerVersion()`/`refreshStreamingSession()` — `PlaybackStatsOverlay`'s Streaming-section backers — no-opping entirely offline (no network call, `serverVersion`/`streamingSession` left `nil`) rather than dispatching a request that can never succeed. Also `assScriptSource(for:)` resolved through the view model rather than through the pure mapping, because the defect worth catching lived in that wiring: three ASS sidecars each resolving to their own file (confirmed to fail against the pre-fix code, which returned the first one for all of them), and a SubRip sidecar resolving to `nil` rather than being handed an ASS script libass would parse as a different track's subtitles. Also `assFonts(fromDownloaded:)`, the offline half of authored-ASS font resolution: the stored sidecars read back under the container's own filenames (not the sanitised path's — that name is what `ASSSubtitleRenderSession` writes the face back out as), a missing file skipped without dropping the rest (a row and its files can diverge via a half-deleted download or a restore without sidecars), and `[]` for a download with no stored fonts, which is both "the container had none" and "downloaded before fonts were stored at all" — neither distinguishable, neither an error. Also (2026-08-24, error handling): `engine.load(...)` throwing a `CancellationError` (a superseded load) leaves `errorMessage`/`failureCategory` untouched, mirroring the live path — and a thrown `PlaybackLoadFailure` carries its `message`/`category` straight through to `errorMessage`/`failureCategory` rather than falling back to a generic message. |
| `AetherPlaybackEngine` (error classification) | `AetherPlaybackEngineClassificationTests.swift` | `category(for:)` — the one piece of `AetherPlaybackEngine`'s error handling that's a plain static function over AetherEngine's own public `PlaybackErrorKind` (a string-backed struct, no live `AetherEngine`/`AetherPlaybackEngine` instance needed to construct one), so the one piece covered directly (everything else in that file wraps a real engine — see "What's *not* covered yet" below). Every known `PlaybackErrorKind` classifies into the right `PlaybackFailure.Category` (`.sourceRateLimited` → `.rateLimited`; `.sourceRefused`/`.dolbyVisionRequiresHardware`/`.hlsPlaylistOnRawLivePath`/`.demuxedAudioLiveUnsupported` → `.refused`; everything else known → `.transient`), and a synthetic unrecognized `PlaybackErrorKind(rawValue:)` a future AetherEngine release might add also falls to `.transient` rather than being silently mis-bucketed or breaking a switch — proving the deliberately non-exhaustive `default:` actually delivers the forward-compatibility `PlaybackErrorKind`'s own doc comment calls out. |
| `StreamFormatDescription` | `StreamFormatDescriptionTests.swift` | The Stats for Nerds stream-format rows (AetherEngine 7.21.0's `sourceVideoStreamFormat` and `TrackInfo` audio detail): codec + profile ("HEVC Main 10"), pixel format + depth, the colour description through AetherEngine's own labels, and audio sampling — each falling back to whichever half is known, a float codec's 0/absent depth left off, and an untagged stream reading as a gap rather than as BT.709. Also the transcode fallback: a Dolby Vision video stream and a TrueHD Atmos track as Jellyfin 10.11.11 sends them decode into the new `MediaStream` fields and format exactly as the engine's probe would. What `AetherPlaybackEngine.stats` reads off a live engine (route gating, telemetry) is not covered, for the same reason as the row above. |
| `PlaybackStatsReport` | `PlaybackStatsReportTests.swift` | The playback stats rows both apps draw (iOS pages them, the Apple TV shows them on one page), run on both platforms: Video keeps iOS's row order and a Dolby Vision source gets its Enhancement Layer row, Audio's decoder row keeps its own id ("Audio Decoder", since Video has a "Decoder" too), Zoom appears only where there is one (not on the Apple TV), an offline session's Streaming section is one "Download" row, Build names the platform's OS version, and the stats button's default is iOS's on both (on in debug, off in release). |
| `PlayerControlsOverlay` (skip step) | `PlayerControlsOverlayTests.swift` | The iOS player's skip buttons and the scrubber's VoiceOver adjustable action share one step, 10s each way, kept within the title (VoiceOver's forward step once stayed at 15s). |
| `DownloadSyncManager` | `DownloadSyncManagerTests.swift` | `syncIfNeeded(client:store:)` against `MockURLProtocol` — pushes every `pendingSync` row's stored position/played/percentage (plus `lastPlayedAt` as `LastPlayedDate`, so Jellyfin's Continue Watching ordering reflects when the item was actually watched offline rather than when the sync happened to reach the server — confirmed live as a real ordering bug this fixes; a row with no recorded watch moment simply omits the field rather than sending a bogus one) to `updateUserData`, clears `pendingSync` (and stamps `lastSyncedAt`) on success, *removes the row outright* (not just clears the flag) when it was also `markedForDeletion`, leaves a row untouched on a failed request for the next trigger to retry, and skips rows with nothing pending (no network call at all) — plus syncing several pending rows independently in one pass. |
| `KeychainStore` | `KeychainStoreTests.swift` | Save/load/delete round-trips against the real Keychain (Simulator keychain access needs no special entitlement for this). |
| `ServerSessionStore` | `ServerSessionStoreTests.swift` | Persistence round-trips across fresh instances, and that `clearCredentials` vs. `clearAll` affect the right subset of state. The first-run welcome flag (2026-09-25): off on a fresh install, persisted once "Get Started" is tapped, untouched by `clearAll()`, and already on for anyone with a server configured — someone who set the app up before the welcome existed mustn't meet it the next time they change server. |
| `OnboardingLayout`, `RotationLock.isPhoneSized`, `CenteredFlowLayout` | `OnboardingLayoutTests.swift` | The sign-in journey's composition against every window size it was designed from: iPhone (compact whatever its size class), iPad portrait/landscape including iPad mini, a narrow Split View window (compact), and a foldable's outer (compact) and unfolded inner screen (landscape at 951pt, which a first-cut 1000pt threshold missed). Which landscape windows count as short (the foldable and iPad mini, not larger iPads). The portrait lock's phone-sized test in both orientations, including the foldable's two screens. And the avatar grid's rows: balanced (five where four fit make 3 + 2, not 4 + 1), one row when everything fits, never zero per row. |
| `SearchHistoryStore` | `SearchHistoryStoreTests.swift` | Persistence round-trips across fresh instances, most-recent-first ordering, re-selecting an existing entry moving it to the front instead of duplicating, trimming to the max-entries cap, per-user scoping, and `remove`/`clear` only affecting the given entry/user. |
| `SearchViewModel` | `SearchViewModelTests.swift` | Empty-query short-circuit, debounced search, error state, results loaded straight from Jellyfin's `/Search/Hints` endpoint (the sole search data source — no separate full-`BaseItemDto` grid), history loaded on `init` and kept in sync by `recordSelection`/`removeFromHistory`/`clearHistory`, `imageURL(for:)` returning `nil` until `loadImagesIfNeeded()` has resolved an `ImageURLBuilder` and then reflecting the session's *current* access token (not one baked in earlier — see `SearchResult`). |
| `SearchResult` | `SearchResultTests.swift` | `SearchHint`→display mapping: subtitle text per item type (year for Movie/Series; for Episode, "S1:E4 · Series Name" combining both halves when present, falling back to whichever half is actually available — including omitting the "S1:E4" label entirely rather than half-filling it when only one of season/episode number is present — and "Collection" for BoxSet, so a collection result isn't mistaken for a regular title), `imageReference` extraction (Thumb preferred over Primary when both are present, falling back to Primary alone, `nil` when neither tag exists), and `imageURL(images:)` resolving that reference fresh against whichever `ImageURLBuilder` it's given — including the case that's the whole reason it's a reference and not a stored `URL`: the same `SearchResult` resolving to a *different* URL once the access token changes, so a history entry persisted under an old token doesn't 401/403 forever after a later re-login. |
| `HomeViewModel` | `HomeViewModelTests.swift` | The multi-endpoint fan-out in `load()` — the hero rail's random-unwatched-movies-and-series query (`IncludeItemTypes`/`SortBy=Random`/`Filters=IsUnplayed`), the libraries rail straight from `/Users/{id}/Views`, rail ordering (Continue Watching, then Next Up, then Recently Added Movies/Shows), remaining rails omitted when empty, `seeAllQuery` wiring — including Recently Added Movies/Shows presetting `initialSortField: .dateAdded`/`initialSortOrder: .descending` rather than the grid's own bare default — and that `loadIfNeeded()` doesn't re-fetch once `loadState` is no longer `.idle` — including the case where every array legitimately loaded empty (a regression net for a guard that used to check `rails.isEmpty` instead, which would've kept re-fetching forever in that case). Also: all four dynamic rail types (genres, studios, actors, directors) appended after the curated set with correctly formatted titles, sharing one shuffle pool rather than being ordered separately, deterministic ordering via an injectable `shuffle` closure (identity in tests, a real shuffle in production), `loadMoreDynamicRails()`'s batching (5 candidates per batch, `hasMoreDynamicRails` tracking exhaustion), a candidate below `minimumDynamicRailItemCount` (5) being dropped the same as a genuinely empty one, `loadMoreDynamicRails()` no-opping rather than double-fetching when called while already loading, and that genre/studio rails' `seeAllQuery` carries the right title/parentID/includeItemTypes/genre-or-studio preset while actor/director rails' stays `nil`. Also (2026-08-18, offline detection): confirmed live that dynamic rail discovery — which fails silently by design, per `load()`'s own doc comment — can have one of its six fetches fail specifically in the window right after reconnecting, leaving those rails missing with no way to retry; `dynamicRailCandidatesFailed` distinguishes that from a library that legitimately has nothing to offer, and `retryDynamicRailCandidatesIfNeeded()` (called by `HomeView` on a `ConnectivityMonitor` offline→online transition) re-runs discovery only when something actually failed, confirmed not to double-fetch or duplicate rails when nothing did. Also (2026-08-24, review pass): a *partial* failure — some of the six discovery calls already turned into visible rails before a sibling call threw — followed by a fully-successful retry must not re-append those already-loaded rails a second time, since the retry re-runs all six discovery calls wholesale; `consumedDynamicRailCandidates` is what `loadDynamicRailCandidates()` filters the freshly-discovered candidates against to prevent that. Also (2026-08-29, offline-mode review): the *primary* load can hit the same reconnect-window problem `retryDynamicRailCandidatesIfNeeded()` was built for, but worse — confirmed live, a cold launch that resumed offline (see `AppState.start()`) showed "You're Offline" until Wi-Fi reconnected, then instantly flashed a stale "Something went wrong loading your library" with no retry at all, since `ConnectivityMonitor.isOffline` flipping `false` (often just a lightweight health-check succeeding) doesn't mean the heavier `/Users/{id}/Views` fan-out can succeed yet. `retryLoadIfNeeded()` (also called by `HomeView` on the same reconnect transition, before `retryDynamicRailCandidatesIfNeeded()`) retries `load()` with backoff (`reconnectRetrySchedule`, injectable so tests don't wait out the real delays) instead of a single immediate attempt, no-opping once already `.loaded`, succeeding on whichever attempt the schedule catches (asserted by counting requests to `/Users/{id}/Views` — `load()`'s first, sequentially-awaited call, so counting it can't race the concurrent siblings a successful attempt fires), and landing back on `.failed` once the schedule is exhausted against a genuinely still-unreachable server. Every `loadState` write routes through `setLoadState(_:)`, which also mirrors it onto `LibraryAvailability.shared` (`.idle`/`.loading` → `.loading`, `.loaded` → `.available`, `.failed` → `.unavailable`) — pinned directly (`test_load_success_marksLibraryAvailable`, the `.unavailable` assertion in `test_load_serverError_setsFailedStateAndLeavesRailsEmpty`) and via the retry tests confirming the mirror survives `retryLoadIfNeeded()`'s intermediate flicker-suppression writes intact. A same-day follow-up fixed a real concurrency bug found live: `retryLoadIfNeeded()` now coalesces concurrent callers (`HomeView`'s own "Try Again", `LibraryAvailability.retryAction` from Search's mirrored one, and the automatic reconnect hook) into one shared attempt via `inFlightRetry`, same idea as `JellyfinAPIClient.inFlightReauth` — previously, tapping "Try Again" while the automatic backoff loop was already mid-cycle could have the loop's own next scheduled attempt fire after the manual tap's `load()` had already succeeded, clobbering that success back down with no further attempt left to recover it, which looked like a "Try Again" tap that just spun forever. `test_retryLoadIfNeeded_concurrentCallers_coalesceIntoOneAttempt` races two calls via `async let` (same technique as `JellyfinAPIClientTests.test_401_concurrentFailures_coalesceIntoASingleReauthentication`) and asserts exactly one `/Users/{id}/Views` request fires. Another same-day follow-up: `defaultReconnectRetrySchedule` was originally 4 retries (mirroring `reauthBackoffSchedule`'s shape), but a 401 retry and a reconnect retry aren't equivalent — a 401 means the server already responded, so each retry is a fast round trip, while a reconnect retry can hit a server that's routable but not answering, costing up to `JellyfinAPIClient`'s own 20s per-request timeout *per attempt*; measured live, 4 retries multiplied that into ~100s of an unmoving spinner before finally settling back to the offline screen. Cut to a single retry (`test_defaultReconnectRetrySchedule_isBoundedToOneRetry` pins the count) to bound the worst case to roughly 2×20s+2s instead. |
| `CollectionGridViewModel` | `CollectionGridViewModelTests.swift` | Query parameters (`parentID`/`includeItemTypes`) reach the client correctly, error state, `loadIfNeeded()` short-circuit, defaulting to `CollectionSortField.title`/`CollectionSortOrder.ascending` (`SortName`/`Ascending`) when `query` carries no presets, `init` seeding `sortField`/`sortOrder`/`selectedGenre`/`selectedStudio` from `query.initialSortField`/`initialSortOrder`/`initialGenre`/`initialStudio` when it does (and that preset sort actually reaches the request), `setSortField(...)`/`setSortOrder(...)` independently reloading with the right `sortBy`/`sortOrder` — including that flipping order doesn't change field and vice versa, and a non-Title field can go ascending too (not locked to descending) — re-selecting the already-current field/order not triggering a redundant request, `availableGenres`/`availableStudios`/`availableDecades` deriving distinct sorted option lists from the currently loaded `items` (decades newest-first) *and cascading*: selecting one facet narrows the *other two*'s option lists down to only values that still co-occur with it (e.g. selecting a genre hides studios/decades that no longer have a matching item), a facet's own selection never narrows its own list (picking a genre doesn't collapse the Genre list to just that one value), narrowing composes across multiple active facets at once, and clearing a filter (or `resetFilters()`) widens every list back out, `availableWatchStatuses`/`availableFavoriteStatuses` folding into the same cascade (watched/unwatched and favorite/non-favorite narrow and are narrowed by the other facets identically, despite being user-data-derived rather than metadata-derived), `filteredItems` narrowing by whichever of `setGenreFilter`/`setStudioFilter`/`setDecadeFilter`/`setWatchStatusFilter`/`setFavoriteStatusFilter` are active — combined with AND across facets, clearing a filter (`nil`) restoring those items, and a combination that matches nothing returning empty rather than erroring — `randomItem()` picking only from `filteredItems` and returning `nil` when nothing matches — and `hasActiveFilters`/`resetFilters` (false with none selected, true with any single one, and resetting clearing every filter and restoring the full list). Also (2026-09-02, Playlists): a Playlists-typed query (`includeItemTypes: ["Playlist"]`) filters out audio-only playlists client-side (`MediaItem.isAudioContent`) while keeping mixed-media ones, and that filter doesn't leak into an unrelated query whose own items happen to carry `mediaType: "Audio"` for other reasons. |
| `AssetDetailViewModel` | `AssetDetailViewModelTests.swift` | The movie/series/season/episode branches in `load()` — only series/season/episode fetch `Seasons`; a Season swaps `item` to its parent Series' own DTO (a Season has no content of its own worth showing) while an Episode keeps `item` as itself, both resolving `seriesID`/`preselectedSeasonID` either way, and both ending up with a `seriesItem` too (the Show's own item — reused from `item` for Series/Season, its own extra fetch for Episode, since `item` there is the Episode, not the Show) — plus `refreshItem()` re-fetching `displayedItemID` (the Series, for a Season load, or a selected Episode — see `selectEpisode(_:)` below) rather than `itemID` afterward. `showPlaybackEpisode`'s resolution: NextUp's fallback chain (in-progress/next-up episode → first episode of the first season that has any, skipping empty seasons, → `nil`, which `isShowWithoutPlayableEpisode` turns into a hidden Play button; also `nil` with no `seriesID`), and `initialSeasonID` opening the episode list on whichever season that target is in for a Series tapped directly, versus always that season's own first episode (never NextUp) for a Season tapped directly — both re-resolved by `refreshItem()` too, since a playback session can change which episode is "next". `selectEpisode(_:)` swapping `item`/`displayedItemID` to a tapped episode row's full item in place, without touching `seriesID`/`seasons`. `toggleFavorite(itemID:currentlyFavorite:)`/`toggleWatched(itemID:currentlyWatched:)` — `POST`/`DELETE` chosen from the passed-in current status, applying an optimistic update (`applyOptimisticFavoriteWatched`) to every property currently holding that id (`item`, `seriesItem`, a `seasons` entry, `showPlaybackEpisode`) the moment the write itself succeeds, then re-fetching that same id (retrying on `userDataCommitPollSchedule`, shared with `refreshItem()` below, until the server actually confirms the new value, since Jellyfin's write endpoints return before the userData change is queryable — the mocked server in these toggle tests always confirms on the first attempt, so that retry loop itself isn't separately exercised here) — since a Show-content page's favorite/watched menu can target any of the Show/Season/Episode independently, not just whatever `item` currently is. `test_toggleFavorite_serverNeverConfirms_keepsOptimisticValueRatherThanRegressingToStaleData` pins the live bug (2026-08-16) this optimistic update fixes: a write that returns success immediately but doesn't actually commit server-side for several *minutes* — confirmed on a real server, an order of magnitude past the poll's ~13s budget — used to leave `item` showing the stale pre-toggle value once the poll gave up, indistinguishable from the tap having done nothing; the poll itself was also changed to only ever adopt a *confirmed* fetch, never patch `item`/etc. from an unconfirmed one, so it can no longer regress the optimistic value back to stale data mid-poll either. `currentFavoriteWatchedStatus(forItemID:)` — the same four-property lookup, exposed for `HeroActionButtons` to call fresh at the moment a toggle fires rather than trusting its own button/menu-row closure's captured `MediaItem`, which a real, separately-confirmed SwiftUI toolbar staleness bug could leave one or more renders behind its own visibly-up-to-date icon. `refreshItem()` actually retrying past a first stale poll response before picking up a changed `playbackPositionTicks` — a live regression (resume a movie, scrub, exit quickly — the new position didn't show up on the detail page within the old, shorter poll window even though the server had it right) that's what `userDataCommitPollSchedule` itself, and its sharing between both methods, is for. `applyOptimisticPlaybackPosition(_:)` — patching whichever of `item`/`showPlaybackEpisode` matches the closed session's `itemID` immediately, leaving the other untouched, and no-opping entirely for a non-matching id — plus the critical interaction between it and `refreshItem()` that a first attempt at this fix missed and shipped broken: `refreshItem()`'s poll used to capture its "did this change?" baseline *after* the optimistic update had already moved `item`, so the poll's near-guaranteed-stale first attempt looked like "a change" and got adopted immediately, silently undoing the optimistic value. Two tests pin the real fix (`optimisticPlaybackTarget`/`optimisticPositionTolerance`): a stale attempt or two get ignored until the server actually catches up, and — if it never does within the whole poll window — the known-correct optimistic value is left in place rather than falling back to whatever stale data the last attempt saw. `preloadedItem` seeding `item` before any load plus still triggering the full fetch (`loadIfNeeded()`'s guard is on `loadState`, not `item`, precisely so a preloaded item doesn't look like "already loaded" and get skipped), and `preferredMediaSourceID(forPlayableItem:)`/`setPreferredMediaSourceID(_:forPlayableItem:)` — the version-choice prompt's remembered answer for a later Resume — round-tripping through `MediaVersionPreferenceStore` and keyed by the *playable* item id, not this view model's own `itemID` (a Show's Play button resolves to a specific episode, distinct from the Series itself). `load()`'s supplementary rails (`similar`/`collections`/`seasons`) each failing independently without flipping `loadState` to `.failed` — only the primary item fetch (and, for a Season load, the Series item it swaps to) still can. `track(_:)`/`cancelBackgroundWork()` — a favorite-toggle confirmation poll that's cancelled mid-flight stops itself (via its own `Task.isCancelled` check) well short of its full retry schedule, rather than the outer `Task` being marked cancelled while the loop runs to completion regardless. `refreshItem()` changing `episodeListRefreshToken` on every call — what `SeasonEpisodeList` depends on to re-fetch a just-played episode's own row (progress bar/watched state) after returning from the player, rather than that list sitting stale until a manual season-picker change. `advanceToNextEpisodeIfCompleted(playedEpisodeID:)` — the "Up Next" auto-advance feature (2026-08-13): once the just-played episode is confirmed `played` (its own dedicated poll, not the unrelated `displayedItemID` one — see that method's doc comment for why the latter can't answer this for Show-direct content), a different NextUp result swaps `item` to it via `selectEpisode(_:)`, from *either* entry point (a Series-direct page becomes Episode content the same way an Episode-content page advances to its own next episode — same code path, `isEpisodeContent` is purely `item?.kind == .episode`) — covering both, plus NextUp-empty (series finished) and never-confirmed-played both correctly leaving `item` alone, and a season-boundary crossing updating `preselectedSeasonID` (which `selectEpisode(_:)` now also keeps current, not just `item`/`displayedItemID`) for `ShowDetailView`'s season picker to follow. Live-confirmed against a real server for the Show-direct entry point (see that method's own doc comment). `collectionItems` — a BoxSet's own children, fetched by `ParentId` alongside `similar`/`collections` in `load()` (and confirmed *not* fetched for a Movie, since the fetch shares its `/Items` path with the unrelated BoxSets-probe request inside `collectionsContaining` — the tests assert on the `ParentId` query param specifically to keep the two apart), then re-fetched again at the end of `refreshItem()` so a movie played directly from `CollectionItemList`'s own play button (which never pushes into that movie's own detail page, so never runs *its* `refreshItem()`) still picks up its new watched/progress state once the player closes. Also (2026-09-02, Playlists): `orderedPlaylistItems` — a Playlist's own member items, fetched via the dedicated `/Playlists/{id}/Items` endpoint (distinct from `collectionItems`' `ParentId`-scoped `/Items` call) alongside `similar`/`collections` in `load()`, preserving server-given order and filtering out audio/music members; `playlistResumeTarget` resolving to the first not-fully-played member, or the first member when every one is (a full replay); `refreshItem()` re-fetching it the same way `collectionItems` is for the same reason (this page's own item poll never "catches up" for a Playlist either); and `applyOptimisticPlaybackPosition(_:)` patching whichever `orderedPlaylistItems` entry matches a just-closed session's `itemID`, alongside `item`/`showPlaybackEpisode`. |
| `AddToPlaylistViewModel` | `AddToPlaylistViewModelTests.swift` | The "Add to Playlist" picker (2026-09-08). `load()` keeping only playlists the server says this user may edit and dropping audio ones, treating an empty result as `.loaded` rather than `.failed` (the sheet still has "New Playlist" to offer, which needs no permission at all), and reporting `.failed` only when the initial browse itself fails. `add(to:)` sending the target's own id — and, for a show, sending the **series** id rather than an expanded episode list, since Jellyfin expands a folder-shaped item server-side and enumerating episodes here would both duplicate that and get it wrong for a show whose episodes this client hasn't fetched. `create(named:isPublic:)` trimming the name, seeding the new playlist with the target, and passing the visibility choice through. And the rule deciding whether tapping an existing playlist stops to confirm: single movies/episodes don't, shows and seasons do, with `expandedItemCount` reading `recursiveItemCount` only for those and falling back to count-free copy rather than claiming "0 episodes" when the server didn't say. A same-day follow-up covers three refinements: `constituentItemIDs` — every id the target actually resolves to (itself for a movie/episode, each episode beneath it for a show/season), resolved once per load and failing soft to empty; `alreadyContainsTarget` marking a destination row only when it holds **all** of those (a playlist with some of a show's episodes is still worth offering, since the user can top it up), and marking nothing at all when the target never resolved — better a redundant add than a row the user can't tap for a reason they can't see; `expandedItemCount` preferring that resolved list over the server's `recursiveItemCount`, which is only populated when something asked for it and on a Season often isn't there; and the copy helpers `addActionTitle` ("Add 6 Episodes", falling back to "Add All Episodes" with no count and a plain "Add" for a single item) and `addedToastMessage`/`createdToastMessage`, which name the destination because the sheet that named it has closed by the time the toast shows. |
| `HeroScrollEdgeScrim`, `HeroStatusBarScheme` | `HeroScrollEdgeScrimTests.swift` | What keeps the status bar and toolbar legible over Home's or a detail page's hero and after it scrolls away. Its cross-fade progress is 0 at rest and while pulled down for refresh, stays 0 until the hero's bottom edge is within the ramp distance of the bars, and reaches 1 as that edge passes under them. It is 1 throughout on a page with no hero. The value is quantised to `progressSteps`, so scrolling outside the ramp reports nothing new. `isOverHero`, which picks light status bar content, flips at the midpoint and is never true without a hero. The material band's solid part ends exactly at the bars. `HeroStatusBarScheme`, which carries the page's status bar colour to the app's root, where iOS 27 decides it: a page's claim sets it, its own release clears it, and a release from a page that has already been replaced (a push shows the new page first) leaves the new page's colour alone. The drawing and the status bar colour are checked by eye, on the device as well as the Simulator, since the two chose different status bar colours before the app set it itself: both are `accessibilityHidden` or system chrome, so no journey can see them. |
| `ToastCenter` | `ToastCenterTests.swift` | The transient-confirmation channel behind `ToastHost` (2026-09-08). Posting makes a toast current; a second post **replaces** the first rather than queueing behind it (two confirmations in quick succession means the second is the one that matters); `dismiss()` clears immediately; a toast clears itself after `visibleDuration`; and a replacement restarts the countdown rather than inheriting the first one's already-elapsed timer. The two timing tests wait the real duration rather than injecting a clock — a fake clock would be more machinery than the behaviour it verifies. Every test resets the singleton in `tearDown`, since a leaked toast would surface in whatever runs next. |
| `AppState` | `AppStateTests.swift` | The `.serverSetup` → `.login` → `.main` phase machine: silent sign-in on launch (success and failure-falls-back-to-login), `completeServerSetup`/`signIn`/`signOut`/`changeServer` all affecting the right subset of state. Also (2026-08-18, offline detection; revised 2026-08-29): remembered credentials rejected by a real HTTP response (401) still fall back to `.login`, while the server being unreachable at all (a `URLError`) resumes the last known session from cache and lands on `.main` directly instead of stalling on a separate offline phase — `restoreSession(accessToken:username:password:)` hydrates the reused `JellyfinAPIClient` from the cached token so `sendRaw`'s existing 401 reauth machinery works once real connectivity returns, and `currentUser` stays `nil` until a real sign-in eventually succeeds (every screen that needs the signed-in user's id falls back to the cached `sessionStore.credentials?.userID` in the meantime — see `PlayerView`'s original use of that fallback). A defensive fallback (remembered credentials present but no cached token/userID — not reachable in practice, since `saveCredentials` is only ever called with both populated) still falls back to `.login`. Quick Connect sessions (2026-09-25), which have no password to sign in with again: launch validates the stored token with `GET /Users/Me` and never calls `AuthenticateByName` (asserted by the exact request list), a revoked token (401) falls back to `.login`, an unreachable server resumes from cache as the password path does, and `signInWithQuickConnect` stores `authMethod: .quickConnect` with no password. `ServerSessionStoreTests` pins that credentials saved before `authMethod` existed decode as `.password` rather than failing to decode, which would sign every existing user out on update. |
| `LoginViewModel` | `LoginViewModelTests.swift` | `canSubmit` gating, delegation to `AppState.signIn`, the user-facing error message on failure. Quick Connect availability following `/QuickConnect/Enabled`, and staying hidden when that check fails rather than offering a button that could only fail. The user grid (2026-09-25): `/Users/Public` loading into the grid, and an empty list or a failed request both falling back to the form rather than an error; a passwordless user signing in on one tap with an empty password (asserted on the posted body); a user with a password selected rather than signed in, and deselected by a second tap; an empty password still submitted for a `HasPassword: true` user, because the demo server says that of an account that takes one; a wrong password keeping the user selected with the error, and the grid back rather than stuck on "Signing in as". The splashscreen only asked for once `/Branding/Configuration` says it's on, and `LoginDisclaimer.plainText(from:)` turning `<br>` into line breaks, stripping other tags, decoding entities in an order that doesn't double-decode `&amp;lt;`, and reducing markup-only text to nothing. |
| `QuickConnectViewModel` | `QuickConnectViewModelTests.swift` | One code's lifecycle, on a 10ms poll interval: the code shown while waiting, polling until approved and handing the *secret* (never the code) to sign-in, a 404 poll read as expired (Jellyfin forgets a code after 10 minutes), one transient poll failure tolerated but repeated ones failing, a refused `Initiate` (Quick Connect turned off answers 401) failing, a sign-in that fails after approval failing, and cancellation — the sheet going away — stopping the poll. |
| `QuickConnectApprovalViewModel` | `QuickConnectApprovalViewModelTests.swift` | Approving another device's code from the Account screen. Entry: digits only, capped at 6 (a pasted "Code: 482 913" lands as the code, and non-ASCII numerals — which `Character.isNumber` accepts — are dropped), Authorize enabled only at 6 digits and never sending an incomplete code, and editing after a failure clearing it. Each server answer's message: success; 404 explaining the 10-minute expiry; 500 naming the already-used case; a 401 told apart by re-asking `/QuickConnect/Enabled` ("turned off" vs "session expired"); offline naming the server. Availability following `/QuickConnect/Enabled` and hiding the row when that check fails. The client side is in `JellyfinAPIClientTests`: no `userId` on the request, and a persistent 401 re-authenticating once only. |
| `ServerSetupViewModel` | `ServerSetupViewModelTests.swift` | `testConnection()`'s address validation, server-name detection/fallback, and unreachable-server handling. `syncHTTPSToggle(withAddress:)` (2026-08-27): keeps the "Use HTTPS" toggle honest when the typed address already has an explicit scheme, which otherwise silently overrides the toggle with no visible sign why. A real, reliably-reproducible bug found the same day (both Simulator and physical device — see `jellyfin-12-upgrade-work-order` memory for the investigation): `testConnection()`'s `GET` ping can succeed even when the toggle never actually took effect, if the server 302-redirects HTTP→HTTPS (confirmed live against `demo.jellyfin.org`) — `URLSession` follows that transparently, masking the wrong scheme until the *non-idempotent* sign-in `POST` goes out on it and fails outright. `testConnection()` now corrects `configuration.baseURL`'s scheme to wherever the ping actually landed (`ServerConfiguration.correctingScheme(usingLandedURL:)`) rather than trusting the scheme it assumed going in — pinned by a test that returns a mock response whose own URL differs from the request's, simulating the redirect. Local-network discovery (2026-09-24): `scanForServers()` publishing servers in answer order and settling on `.finished` (with or without any), a failure keeping whatever answered before it, a rescan replacing rather than appending, and `connect(to:)` filling the address field from the discovered URL — base path included, HTTPS toggle following its scheme — then testing it exactly as a typed address, so an unreachable one is left in the field with the usual error. The HTTP fallback for a discovered `https://` server whose certificate fails: offered (not connected) when HTTP on 8096 answers with the discovery reply's `SystemId`, on the same host and base path; never offered for a different `SystemId`; the port asked for when 8096 is silent, then offered on the port given, asked again with the reason when that port is silent too, and an invalid port never probed; accepting returns the already-tested configuration, cancelling keeps the explanation; and a non-certificate HTTPS failure never tries HTTP at all. The Local Network prompt (2026-09-24, both seen on device): a connection that fails behind it waits for the app to become active again and retries once, whether the failure carried the local-network-denied reason or only coincided with the app going inactive; "Don't Allow" and access switched off earlier (no prompt, app never inactive) both end on the Local Network message; and an ordinary failure neither waits nor retries. Driven by a fake `AppActivityObserving` and an injected denied-reason check, since neither the prompt nor its error exists off-device. Requests are counted by host and path only: the unit tests run inside the host app, whose own launch traffic reaches `MockURLProtocol` too. All against a stub `ServerDiscovering`; the socket side is `ServerDiscoveryTests`. The scan on arrival (2026-09-25): starts once, and coming back to the screen leaves its results alone rather than scanning over them. Each discovered server's version looked up in the background, a server that can't be asked (an `https://` address with a failing certificate) simply having none and no error, and at most one lookup per server however many rescans list it. Scan tests that aren't about versions pass a no-op lookup: the real one's request can outlive its test and land in the next one's `MockURLProtocol` handler. |
| `ServerDiscovery` | `ServerDiscoveryTests.swift` | `JellyfinDiscoveryProtocol.parseReply` against a reply captured verbatim from a 10.11 server (PascalCase keys, `Address` carrying the base path), a blank `Name` falling back to the host, and rejecting anything that isn't a usable reply. `LocalSubnet.hostAddresses`: a /24 probes every host but the network and broadcast addresses — *including* the device's own, which is how the Simulator finds a server on its own Mac — a /22 is probed whole, anything wider narrows to the device's own /24, and /31–/32 probe nothing. `ScanSchedule`: an accepted probe listens for the window then stops, all-refused gives up after the grace period as denied, the scan never ends while the app is inactive (under the prompt probes are silently dropped), reactivation starts over, and the 60s hard stop holds regardless. The live scan (`LANServerDiscovery`) is not unit-tested — it needs a real network; verified in the Simulator against a real server, and the UI suite swaps in `UITestServerDiscovery`. |
| `PlayerViewModel` | `PlayerViewModelTests.swift` | Resume-position seeking (and the `startFromBeginning` override), playback-start/-stop reporting with correctly converted tick values, transport controls delegating to the engine, engine→ViewModel state/time callbacks, version selection (`requestedMediaSourceID` scoping the `/PlaybackInfo` request and selecting the matching source over `.first`, an unrecognized requested id falling back to the server's default rather than failing, and `activeMediaSourceID` — whichever source actually got resolved — being reported alongside the start/progress/stop session calls), `setZoomMode(_:)` delegating straight through to the engine, `stats` passing through the engine's diagnostics snapshot unchanged, `sourceVideoStream` being set from the resolved media source's own video stream (not just its first stream), `refreshServerVersion()`/`refreshStreamingSession()` — the Streaming section's server-version fetch-once-and-cache behavior, and the live `/Sessions` poll populating play method and (only while transcoding) live transcode parameters, leaving the last known value in place on a failed request — `isOfflinePlayback` reading `false` for a live (non-downloaded) session, the flip side of `PlayerViewModelOfflineTests`' own `true` case — `externalSubtitleSources(from:client:)` mapping a resolved source's `isExternal == true` subtitle `MediaStream`s (Jellyfin sidecar files) onto `ExternalSubtitleSource`s passed into `engine.load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`, leaving embedded streams alone (they arrive through the demuxer already) and skipping a stream whose `deliveryUrl` can't resolve into a URL rather than failing the whole load — and `atmosAudioTrackIndices(from:)` deriving the audio-track-index hint set from `MediaStream.audioSpatialFormat == "DolbyAtmos"` (server-reported, not codec/title text-matched — see that field's own doc comment), excluding a non-Atmos audio stream and a non-audio stream carrying the same field, and — a real bug found live, 2026-08-14 — correcting Jellyfin's reported `index` for any `isExternal == true` streams preceding it in the same source, since those consume slots in Jellyfin's index sequence without existing in the physical container AetherEngine actually demuxes (confirmed on a real Saving Private Ryan source: one external subtitle at index 0 shifted every embedded audio stream's reported index one higher than AetherEngine's own numbering for the identical tracks) — and, restoring a remembered track choice (`TrackPreferenceStore`), `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` looking up the selected track's own title off the engine and persisting it alongside the id (including explicit "Off", which persists unconditionally with no title to look up), `start()` re-applying a stored choice after `engine.load(...)` returns (overriding whatever default/forced-subtitle selection the load just settled on), a fresh item with nothing stored leaving that default selection untouched, a stored id no longer present in the freshly loaded track list being skipped rather than passed through, and — the case a bare id-existence check can't catch — a stored id that's still present but whose *title* no longer matches (the layout reordered without the track count changing, e.g. a different version resolved) also being skipped, since track ids are just physical container positions rather than stable identifiers — and `startPictureInPicture()` delegating to the engine, and the engine's `onPictureInPicturePossibleChange`/`onPictureInPictureActiveChange` callbacks updating `isPictureInPicturePossible`/`isPictureInPictureActive` — and `start()` staging the lock screen/Control Center Now Playing title and subtitle (`MediaItem.railTitle`/`.railSubtitle`) via `engine.setNowPlayingInfo(title:subtitle:artwork:)` synchronously, ahead of the separate `RemoteImageLoader`-backed artwork fetch that isn't exercised here — and the in-player "Up Next" prompt: `start()` resolving `nextEpisode` for `.episode` content via `JellyfinAPIClient.nextEpisode(...)` (and never even attempting the lookup for a Movie), `nextUpSecondsRemaining` staying `nil` outside the configured countdown window and reporting the correct remaining-seconds value once `duration - currentTime` falls inside it (driven by simulated `onTimeUpdate` calls, with no separate timer of its own — see that property's doc comment), `dismissNextUp()` keeping it `nil` for the rest of the item's playback even after scrubbing back into the window, `NextUpPreferenceStore`'s `.off` setting suppressing it entirely regardless of position, and `closesWhenPlaybackEnds` — true with nothing queued, the countdown off or Up Next cancelled, but false while a next item is queued (PiP included), so `PlayerView` closing on `.ended` never pre-empts the auto-advance — and skippable segments (Jellyfin's Media Segments feature, 2026-08-17): `start()` resolving `mediaSegments` via `JellyfinAPIClient.mediaSegments(itemID:)` unconditionally (unlike `nextEpisode`, this isn't episode-only), `currentSkipSegment` returning whichever segment contains `currentTime` and `nil` outside all of them, an item with more than one `.outro` segment (a mid-content credits roll plus true end credits — Jellyfin has no separate segment type for the two) only ever deferring the *later* one to the Up Next card while the earlier one still gets its own plain "Skip Credits" button, and the end-credits override on `nextUpSecondsRemaining`/`nextUpTotalCountdownSeconds`: once such a segment exists, its own start time fully replaces the duration-relative trigger (confirmed with the user, 2026-08-17) — staying `nil` until the segment starts even if the configured preference window would have fired earlier, and firing right at the segment's start with a fixed 10s countdown even if that's earlier than the configured window would have — and `skipSegment(_:)` seeking to the tapped segment's end while immediately hiding `currentSkipSegment` — confirmed with the user (2026-08-17) this needs to happen right on tap, not once `currentTime` actually catches up to the seek target, which can lag behind by a whole buffering spell — and the end-credits countdown's scrub-landing fix (2026-08-18): scrubbing straight past where the countdown's own trigger point would already have elapsed used to compute an instantly-clamped-`0` `remaining` and silently auto-advance with no countdown UI ever shown, fixed by timing the countdown off `nextUpCountdownAnchorTime` (reset by every `seek(to:)`, not `endCreditsSegment.startSeconds` directly) so a scrub landing anywhere inside the segment always gets a fresh countdown from wherever it actually lands, capped to however much real duration remains when that's under 10 seconds — and a follow-up fix the same day: `nextUpSecondsRemaining` used to round a fractional `remaining` *up*, reading one higher than the scrubber's own truncating "time remaining" label (`PlayerControlsOverlay.endTimeText`/`formatTime`) for the entire time in between whole seconds, in both the end-credits and plain duration-relative branches — now truncates instead, matching that label exactly — and the scrub-preview bubble: `scrubThumbnail(atSeconds:)` returning `nil` before `start()` has resolved anything, `supportsScrubThumbnails` becoming `true` once `start()` resolves a `TrickplayInfo` entry keyed to the actual resolved media source, and staying `false` when the item's `trickplay` dict has no entry for it (see `TrickplayThumbnailProviderTests.swift` above for the tile-fetch/crop math itself, which lives outside this view model). Uses `FakePlaybackEngine` (Support/) rather than a real `AetherEngine`. Also (2026-08-18, offline detection during playback): a terminal `.failed` state reaching `onStateChange` — not just a thrown error from `start()` — populates `errorMessage` (previously silent: the video just froze with no message, the only visible trace being the diagnostics-only "stats for nerds" overlay), and an explicit `resumeSeconds` passed to `start(resumeSeconds:)` (the connectivity-loss retry path) seeks there, overriding both `startFromBeginning` and the server's own last-known resume position. Mid-stream reconnect UI itself (`.reconnecting`, `PlayerControlsOverlay`'s "Reconnecting…" label, and `PlayerView`'s offline-vs-generic-error overlay choice keyed on `ConnectivityMonitor`) needs manual/on-device verification — see "What's *not* covered yet" below. Also (2026-08-24, error handling): a `.failed` state now carries a `PlaybackFailure` (`message` + `category`), not a bare string — `errorMessage`/`failureCategory` both derive from it; `engine.load(...)` throwing `CancellationError` (a superseded load — rapid next-episode navigation, backing out mid-load) leaves both untouched rather than showing a spurious error, while a thrown `PlaybackLoadFailure` carries its `message`/`category` straight through instead of falling back to the generic "Playback failed to start." Also (2026-08-24, error handling, found live): `stop()` skips `reportPlaybackStopped` entirely while `ConnectivityMonitor.shared.isOffline` rather than awaiting a call already guaranteed to fail — see "What's *not* covered yet" below for the on-device stall this fixes. Also (2026-09-02, Playlist queue mode): a non-empty `playbackQueue` resolves `nextEpisode` by a plain local index lookup (`queue[currentIndex + 1]`) with no network call at all — not gated to `.episode` content the way the per-series lookup is, so a Movie's own next item resolves too — winning outright even when the current item is itself an Episode reached via a playlist (regression guard against silently falling back to the per-series `nextEpisode(...)` API path), and leaving `nextEpisode` `nil` at the last item in the queue. Live-confirmed against a real server (2026-09-02): a mixed movie/episode Playlist's grid card, detail page (no synopsis, correct per-kind item-list metadata — landscape thumbnail + "Series, SxEy · Title" for an episode member, poster + "year, duration" for a movie member), and Play/Resume button label (`PlayResumeButtonRow.titleOverride`) all confirmed on-device; the in-player Up-Next auto-advance chain itself still needs manual verification per this file's Player-screen limitation below. Also (2026-09-08, playlist item removal): `canEditPlaylist` fetched via `JellyfinAPIClient.playlistUserPermissions` alongside `orderedPlaylistItems` in both `load()` and `refreshItem()`, defaulting to `false` when the server has no permission record at all (a 404, mapped to `nil`) — the same fail-closed direction `canDelete` takes; `removeFromPlaylist(_:)` — optimistic (the target is removed from `orderedPlaylistItems` before the network call even starts, unlike `delete(_:)`'s wait-for-success), keyed by `MediaItem.playlistItemID` rather than `id` so one copy of a duplicated item can be removed independently of the other, reinserting at its original index and rethrowing on failure. Also (2026-09-22, the transcode subtitle path): a server-chosen transcode registering the container's own text tracks as sidecars — the embedded ASS one as `/Subtitles/6/Stream.ass`, the burned-in PGS one not at all — since the server's HLS carries no rendition for them and before this every embedded text track vanished from the picker; and one of those registered tracks resolving back to its OWN script through `assScriptSource(for:)`, which `jellyfinStream` cannot do because it pairs embedded tracks, so a sidecar previously resolved to nothing and rendered unstyled. |
| `PlaybackRequest` | `PlaybackRequestTests.swift` | `id`'s inclusion of `startFromBeginning` and `mediaSourceID`, so a Restart-after-Resume or a different version picked on a second Play each present a fresh sheet. |
| `MediaVersionPreferenceStore` | `MediaVersionPreferenceStoreTests.swift` | Persistence round-trips across fresh instances, overwriting a previous choice for the same item, and per-user/per-item scoping — same shape as `SearchHistoryStore`'s tests. |
| `TrackPreferenceStore` | `TrackPreferenceStoreTests.swift` | Same persistence-round-trip/overwrite/per-user-scoping shape as `MediaVersionPreferenceStore`'s tests, plus the audio/subtitle split: recording only an audio choice leaves `subtitlePreference` at `.unset` rather than fabricating one, and a `nil` subtitle selection persists as `.off` — a real, distinct-from-unset remembered choice — rather than clearing the entry. Each stored choice (`TrackChoice`) carries the track's title alongside its id, not just the id — `PlayerViewModel.applyStoredTrackSelection()` re-checks both before restoring, since ids alone are physical container positions that can silently point at a different track next time. Also (2026-08-31, bounding the store): a `maxEntries`-past-cap write evicts the least-recently-*updated* entry (a re-write moves an entry back to "most recent", protecting it from the next eviction) while leaving everything under the cap untouched, and `selection(forItem:userID:)` being reachable with no context/media-source parameter at all is itself asserted (`test_selection_isSharedAcrossPlaybackContexts`) as a regression guard for that keying invariant — not a claim that live/downloaded restoration actually succeeds end-to-end, which (same date, tested live on Office Space) turned out to be unreliable for subtitles and was dropped; see the store's own doc comment. |
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

| Authored-ASS subtitle geometry | `ASSSubtitleGeometryTests.swift` | The drawable region and margins handed to libass, in both orientations and full-bleed. The region is the picture intersected with the safe area, bottom raised for the transport chrome: the overlay ignores the safe area (it has to, to sit over a full-bleed video), so in landscape a corner-aligned sign drew underneath the rounded corner and the sensor housing and was physically cut off — invisible in a screenshot, since the framebuffer has no corners. Pillarboxed landscape is the counter-case, where the bars are wider than the inset so the picture's own edge wins and the horizontal margins come out at zero. The frame starts at the picture's top edge rather than the overlay's, so there is no top margin for `ass_set_use_margins` to relocate a top-aligned sign into (in landscape the picture already starts there, so the shift is a no-op — asserted, since it would be easy to assume otherwise). And the margins are SIGNED: portrait letterboxes, so the bottom margin is positive and dialogue has real empty space to move into; landscape fills the screen vertically, so the frame stops short of the transport chrome and the margin goes negative — libass' documented "the frame is inside the video" case. Clamping it to zero (as the first version did) told libass the picture ended where the frame does and mapped every `\pos` sign into a too-short rectangle, measured at y 20–34 against a correct 29–49 and 30% undersized; portrait was unaffected because its margins are positive, so this was landscape-only and invisible to every portrait check. The load-bearing assertion is the round trip — frame minus margins must recover the real picture height — which holds in both orientations and with the controls up or down, and which fails on the clamped version. Also `fontScale`, the compensation for libass scaling regular events to the frame rather than the video area: exactly 1 in portrait (asserted as an exact equality, since any other value would resize every portrait subtitle in the app — the common case, and correct before the compensation existed), `pictureHeight / frameHeight` in landscape where the frame is the shorter of the two, never below 1, and 1 for degenerate geometry (a zero-height picture, before `videoNaturalSize` has settled). The property it exists for is asserted directly across all six configurations: `min(frame, picture) * fontScale == picture`, i.e. a regular event is laid out as though the frame were the picture. |
| Authored-ASS subtitle mapping | `ASSSubtitleMappingTests.swift` | The two pure decisions behind styled subtitles. `PlayerViewModel.isAuthoredASS(_:)` — which codecs go to libass at all (`ass`/`ssa`, case-folded) and which stay on `SubtitleOverlayView`'s own cue path (SubRip, WebVTT, mov_text, every bitmap format, `nil`); getting it wrong doesn't degrade styling, it sends a track to libass that has no ASS script to fetch. And `isAuthoredASSPath(_:)`, the downloaded-sidecar counterpart, which reads the extension because `DownloadedSubtitleFile` records no codec. Then the mapping itself, `jellyfinStream(forTrack:engineTracks:mediaStreams:)`: AetherEngine numbers an embedded track by its `AVStream` index while Jellyfin numbers the same track by its own `MediaStream.index`, and the two disagree in practice (engine id 2 against Jellyfin index 3 on one file, id 5 against index 6 on another), so they're paired by ordinal among embedded ASS entries. Most of these cases are about that ordinal staying meaningful — bitmap streams interleaved between the ASS ones, external sidecars, and audio/video streams sharing the same index sequence all have to be filtered out of BOTH sides identically, since counting any of them shifts the ordinal and silently fetches a different track's script (which reads as a subtitle-timing bug, not a mapping one). Plus the two nil cases: a non-ASS track, and the two sides disagreeing about how many ASS streams exist, which is not a case to guess at. Plus the sidecar mapping `registeredSidecar(forTrack:engineTracks:registered:)`, the same ordinal rule serving both the offline and transcode paths: each track resolving to its OWN registered thing (the defect being a download with three ASS tracks resolving all of them to whichever sidecar was first on disk, so picking a commentary played the SDH script — real subtitles for the wrong track), ids deliberately sharing no arithmetic with Jellyfin's indices so a mapping matching on the number finds nothing, embedded tracks excluded from the count since a downloaded MP4 can carry its own, and `nil` both for a track this app didn't register and when the two sides disagree on how many sidecars exist — a dropped registration slides every ordinal after it, which is the difference between showing no subtitle and confidently showing the wrong one. Plus which streams become sidecars at all, `externalSubtitleStreams(from:isRemoteHLS:)`: on a transcode the container's own text tracks are included (Jellyfin reports `deliveryMethod: "External"` for exactly those, and `"Encode"` for the bitmap ones it burns in), on direct play only the genuinely external ones — the route gate being load-bearing rather than cautious, since direct play reports the same `"External"` for streams the engine has already listed and registering sidecars there would show every track twice — with a missing `deliveryMethod` (Direct Play Always sends no `DeviceProfile`, so the server describes no route) still registering real sidecars, and non-subtitle streams ignored. Plus which fonts render a script, `assFonts(engineAttachments:fetched:)`: AetherEngine's own probe wins whenever it has anything, the fetched set is the whole answer when it doesn't, and the two are deliberately never merged — on a direct play they are the same faces out of the same container, so a union registers each one twice, and a container carrying fonts never probes to an empty list, so there is no partial case to serve. Neither side having any is not a failure either: libass falls back to a system face, which is how every authored track behaved before fonts were fetched at all. Plus the Subtitle Styling setting's read, `isStyledASSEnabled(_:)`: an unset key means ON (the trap being that `UserDefaults.bool(forKey:)` reports `false` for a key never written, which would ship the feature off for everyone who never opened Settings), the declared default is asserted separately from that so the two can't drift apart, an explicit `true`/`false` is honoured, and the setting is kept distinct from the codec predicate — `isAuthoredASS` stays truthful about what a track *is* with styling off, since `handleSubtitleTrackChange` needs both answers and conflating them would make "is this ASS?" mean two different things in two places. Each case runs against its own throwaway `UserDefaults` suite rather than the shared domain. |

## What's *not* covered yet

- **SwiftUI views, as views** — no snapshot tests. Views here are mostly thin
  (`body` wired to a ViewModel's published state), so the ROI is lower than
  the ViewModel layer underneath them. The UI suite now covers the same
  layout regressions end-to-end across an iPhone and an iPad, which is why
  `swift-snapshot-testing` is still deferred rather than adopted — revisit if
  visual regressions start slipping through anyway.
- **`AetherPlaybackEngine`** itself — still untestable in the traditional
  sense (it wraps a real `AetherEngine` instance, which needs real media and
  a real display to construct). `PlayerViewModel` — the thing that actually
  has logic worth pinning down — *is* now covered, via `FakePlaybackEngine`
  standing in for it. (2026-08-24, error handling) Two more real-engine-only
  pieces added this pass, neither exercisable without one: the seek
  watchdog (`seek(to:)`'s 8s timer that turns a stuck backward-seek — the
  AetherEngine "wedge," upstream issue #93 — into a visible `.failed` state
  instead of a silent freeze; ~50% reproducible per prior on-device
  testing, so it's also hard to provoke *deliberately* even manually — the
  plan is to leave its diagnostic log line in place and watch for it during
  normal use rather than trying to force it), and Picture-in-Picture
  failure logging (`handlePictureInPictureFailedToStart(_:)`, previously
  discarding the `Error` entirely with no diagnostic trail). `category(for:)`
  — the `PlaybackErrorKind → PlaybackFailure.Category` classifier — is the
  one exception: a plain static function over a value type, no engine
  needed, so it *is* covered directly (see the table above). `AetherPlaybackEngine`
  also has a few more pure `private static` helpers (`describe`, `normalize`, `title(for:providedName:)`,
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
  Three more real bugs found live in this same untestable territory
  (2026-08-20, pause a session without exiting the player, lock the phone,
  wait a couple of minutes, unlock): AetherEngine's own `#127`
  background-teardown grace window (`backgroundTeardownGraceSeconds`,
  15s default) releases a paused session's decode pipeline for
  suspension-safety, and its own doc comment on `reloadAtCurrentPosition()`
  says reloading on foreground return is the *host's* job — this app never
  did, so `play()` afterward silently no-opped against a torn-down session
  until the player was backed out of and restarted; fixed with a
  `didBecomeActive` observer that calls `reloadAtCurrentPosition()`
  proactively (plus a defensive fallback inside `play()` itself for
  whatever races past it). That reload's own `LoadOptions.autoplay`
  (inherited from the original `load()` call, always `true` here) then
  autostarted playback the reload was meant to *recover*, not resume — the
  user's actual last action was pause — fixed by pausing again immediately
  once the reload settles. That pause-after-reload was itself wrong, and
  took until 2026-09-19 (and a downloaded item, on device) to surface: it
  worked on the software path and wedged the native (AVPlayer) one on a
  permanent spinner, because the reload's autostart writes
  `state = .playing` before AVPlayer has reported any rate, so the `pause()`
  lands with AE#440's `hasTransportRolled` still false, AVPlayer's first
  `.waitingToPlayAtSpecifiedRate` writes `state` straight back to
  `.playing`, and the `.paused` that follows only lowers `state` once the
  transport has rolled — which it never did. `PlaybackPhase.derive` reports
  that combination as `.loading` forever, which is a spinner where the
  play/pause button belongs. Fixed by mounting the rebuild paused in the
  first place — `reloadAtCurrentPosition { $0.autoplay = false }`,
  AetherEngine's AE#460 option-applying reload — so nothing writes
  `.playing` and the load's own readiness waypoint settles it. A paused
  mount then publishes no clock at all, so `pausedRebuildAnchor` stands in
  for the engine's zeroed one in both time bridges until a real tick, a
  seek or a fresh load supersedes it — without it the scrubber reads 0:00
  and `PlayerViewModel`'s progress reporter persists that as the resume
  position. And the recovered-but-paused state also showed
  the correct playhead but a scrubber pinned at the left edge and a
  "-0:00" remaining-time label: `onTimeUpdate` only ever fired off
  `engine.clock.$currentTime`'s ticks, which stop the instant a session is
  paused, so a `duration` that settled after the last tick a paused
  session would ever produce never reached `PlayerViewModel` — fixed by
  bridging `engine.$duration`'s own independent publisher directly,
  instead of only sampling it opportunistically off the clock.
- **Most user journeys.** There *is* a UI suite now (see "UI tests" below),
  covering auth, Home, the collection grid's sort/filter/random controls,
  all four asset-detail layouts (including a playlist's About panel showing
  only when it has a description), search, the player (transport, the track
  picker, the chapter picker, paging through Stats for Nerds), Downloads (enqueue → complete → bulk delete, Select → Cancel
  leaving everything in place, and a row leaving "Preparing download…" on
  its own when its download finishes with the tab open),
  Profile's two account actions, server-side deletion (the permission gate
  in both directions, the confirmation warning, and delete → pop → gone from
  the grid), playlist item removal (the permission gate, and the
  context-menu path — a long-press menu is this feature's only removal
  path; a swipe gesture was tried and reverted after on-device testing,
  see `PlaylistItemList.onRemove`'s doc comment), adding an asset to a
  playlist (the picker's `canEdit` filter in both directions, the
  single-item-adds-immediately vs. show-confirms-with-a-count split, the
  confirmation's Cancel action and its "Add 6 Episodes" title, destinations
  that already hold the target coming back disabled — both seeded and after
  an add this journey performed — the confirmation toast naming its
  destination, and create → the new playlist is listed afterwards), and the
  `serverError`/`unauthorized`/`offline` scenarios, plus a
  `performAccessibilityAudit()` pass over every
  screen — 71 tests across the smoke plan and the full plan, run against
  both an iPhone and an iPad nightly. What the audits deliberately do *not*
  gate on is contrast, Dynamic Type and text clipping; those are real
  findings but design-level ones, and they are recorded with counts under
  "Accessibility audits" below rather than suppressed quietly.
  One narrower gap inside what *is* covered: swiping a
  search-history row away isn't automated (`SearchResultRow` wraps the whole
  row in a `Button`, and a synthesized `.swipeLeft()` on it can register as a
  tap instead — reopening the row instead of revealing the delete action).
  Re-tapping the Search tab to reset it isn't automated either, but for a
  different reason than it first looked like: on iPad, the floating tab bar
  disappears from the accessibility tree entirely once the search field has
  ever been engaged, and popping back to the results list doesn't bring it
  back on its own — not a bug, tapping away from the search field (confirmed
  live) is the real, working way out, it's just a gesture XCUITest's
  synthetic taps couldn't be made to trigger here (status bar, empty scroll
  content, and the nav bar's own edge were all tried and none registered as
  resigning the field). Automating this journey needs either a different
  synthesis approach or a device.
- **The offline-download engine's background `URLSessionDownloadTask`/
  `AppDelegate` relaunch wiring** (`DownloadManager.enqueue`/
  `startVideoDownload`/`adoptInFlightDownloads`/
  `handleBackgroundSessionEvents`, `DownloadTaskRouter`,
  `AppDelegate.application(_:
  handleEventsForBackgroundURLSession:completionHandler:)`) — `MockURLProtocol`
  only intercepts `data(for:)`/`data(from:)`, not delegate-based download
  tasks, and Simulator background-session behavior diverges from a real
  device regardless. `DownloadManager.delete(itemID:)`'s own logic — the
  part that actually has business rules worth pinning down — *is* covered
  (`DownloadManagerTests.swift`, see the table above); what isn't is a real
  download actually landing bytes, surviving backgrounding, or resuming
  after the app relaunches mid-download. What *is* now covered through the
  DI seams, and is worth keeping there: the single-background-session
  identifier (`makeBackgroundConfiguration()` must never go back to one
  identifier per item — see DOWNLOADS.md's "A background session per
  download exhausted the transfer service"), cancel-on-delete targeting the
  *task*, the retryable/non-retryable classification of transport errors,
  the automatic-retry budget and its slot accounting, and that a -997 never
  reaches a row as iOS's own "Lost connection to the background transfer
  service" string.

  **Capturing device evidence for a background-transfer bug**: reproduce on
  a physical device, then collect the window retrospectively — `log stream
  --device-udid` was removed in recent macOS, but `log collect` still takes
  it (and needs `sudo`):

  ```sh
  sudo /usr/bin/log collect --device-udid <UDID> --last 15m --output before.logarchive
  /usr/bin/log show before.logarchive --info --debug --style compact \
    --predicate 'process == "nsurlsessiond" OR subsystem == "com.apple.CFNetwork"' \
    | grep -E 'dionysus|-997|-996|BackgroundSession'
  ```

  Get `<UDID>` (the hardware UDID, not the CoreDevice identifier) from
  `xcrun devicectl device info details --device <identifier> | grep udid`.

  Verify this slice manually on a
  physical device: download an item, confirm HEVC decode and the right
  audio track/subtitles work in Airplane Mode (an HDR source downloads and
  plays back fine here too, just tone-mapped to SDR — see the README's
  Known limitations section, a confirmed permanent Jellyfin server
  limitation, not something to chase further in this slice), confirm
  background continuation when the app is backgrounded (not force-quit)
  mid-download, and confirm reconnecting actually pushes local
  watched/resume state via `DownloadSyncManager`.
- **Mid-playback connectivity loss, on-device** (2026-08-18) — the
  `PlaybackState.reconnecting` bridge, `PlayerControlsOverlay`'s
  "Reconnecting…" label, and `PlayerView`'s offline-vs-generic-error overlay
  choice all need a real dropped/retrying source connection (AetherEngine's
  own HTTP reader, not `JellyfinAPIClient`) to exercise meaningfully —
  `PlayerViewModelTests` pins the ViewModel-level logic (`.failed` →
  `errorMessage`, `resumeSeconds` override) directly via `FakePlaybackEngine`,
  but not the live reconnect UI. The Player screen is also the one place
  `ios-simulator-skill`'s `idb`-based automation doesn't work at all (see
  `CLAUDE.md`), so this needs manual verification: start playback, then cut
  the server's network mid-stream.
- **The Close-vs-Retry error UI, on-device** (2026-08-24, error handling) —
  `PlayerView`'s branch on `viewModel.failureCategory == .refused` (Close
  only, no Retry) vs. `.rateLimited`/`.transient` (Retry only) is pinned at
  the `PlayerViewModel` level (`errorMessage`/`failureCategory` set
  correctly per test above), but the actual rendering can't be — confirmed
  live on a physical device (a temporary `#if DEBUG`-gated env var swapped
  in a well-formed-but-nonexistent item id so the real server 404s the
  stream request, driving a genuine `.sourceRefused` classification; removed
  before merging), which caught three real bugs no unit test could have:
  - `ErrorStateView`/`OfflineStateView` have no opaque background of their
    own — fine everywhere else they're used (a plain content-region
    replacement), but here `PlayerControlsOverlay`'s transport chrome is
    still fully mounted right underneath and visibly bled through every gap
    around the icon/text/buttons. Fixed with a dimming scrim (`Color.black
    .opacity(0.4)`, light enough to keep the always-present top toolbar/
    title legible — an earlier, much heavier 0.85 crushed them) plus a
    bounded card in the same panel language `PlayerControlsOverlay`'s own
    track picker already uses (`Color(white: 0.1)` fill, `cornerRadius: 14`,
    `Color.white.opacity(0.12)` stroke, matching shadow) — nested `.frame`/
    `.fixedSize` caps what would otherwise be each component's own
    full-screen fill down to a real contained box.
  - Inside that card, `.secondary` (icon/message) and the app's default
    accent color (buttons) both assume they're painting onto the *system*
    appearance, which every other screen using these components actually
    is — against this always-dark card, a device in Light mode read as
    illegibly low-contrast. Fixed with `.colorScheme(.dark)` on the card's
    subtree (forces `.secondary` to its dark-appearance value regardless of
    system setting) plus `.tint(.white)` on `ErrorStateView`'s buttons
    specifically. That "specifically" matters: a first pass applied
    `.tint(.white)` to the whole card indiscriminately, which also caught
    `OfflineStateView`'s primary action — `.buttonStyle(.borderedProminent)`
    uses tint as its *fill*, not just label/border color like `.bordered`
    does, so forcing it white produced a white-on-white button with no
    visible label at all. Verified via computed WCAG contrast ratios
    against the actual colors in play (~6:1 icon/message, ~11:1 buttons) —
    both comfortably pass AA.
  - `stop()` unconditionally awaited `reportPlaybackStopped` regardless of
    connectivity — harmless normally, but `sendRaw`'s own 20s timeout race
    against a call already guaranteed to fail (there's no server to reach;
    that's the entire reason the offline screen exists) meant *every* close
    affordance — the top bar's X, or the offline screen's own Close button
    — read as completely unresponsive for up to 20 seconds while genuinely
    offline. Fixed by skipping the call outright when `ConnectivityMonitor
    .shared.isOffline`; pinned by `test_stop_whileOffline_
    skipsNetworkCallAndStillStopsEngine` (`PlayerViewModelTests.swift`),
    which fails loudly — a throwing request handler, not just an assertion
    — if a regression reintroduces the call.
  Also added while doing this pass: `OfflineStateView` in the Player now
  offers a Close action alongside Retry (previously Retry-only), and
  `PlayerControlsOverlay.isBuffering` now covers `.idle` — `PlayerViewModel
  .state` sits at `.idle` for the entire window `start()` spends fetching
  the item/playback info/stream URL over the network, before `engine.load()`
  is ever reached, and that window showed no loading indicator at all
  (confirmed live, most visibly while offline: a plain, tappable-looking
  transport row with nothing actually happening). The `setUpIfNeeded()`
  `AetherPlaybackEngine()` construction-failure path (previously silently
  swallowed with `try?`, now surfaces `setupError`) is still hard to
  provoke naturally — reviewed by code inspection instead of forced live.

## UI tests

`DionysusPlayerUITests` drives the real app in the Simulator via XCUITest.
It exists because the regressions this project actually ships are layout and
navigation ones — the rotation-lock break, the Home→Detail push, the
`LazyHStack` layout hang — and none of them are reachable from a ViewModel
test.

Three things make it deterministic. All are `#if DEBUG` and verifiably absent
from a Release binary (`nm -a` on the Release build finds none of them).

**A launch-argument harness** (`Core/UITestSupport/UITestHarness.swift`),
invoked from `DionysusPlayerApp.init()` — before `AppState` is constructed,
because `ServerSessionStore` reads `UserDefaults` and the Keychain in its own
initializer. `-UITestResetState` clears both (the Keychain matters: it
outlives the app container, so without it one test's sign-in seeds the next
test's "first launch"); `-UITestSeedSession` plants a session so a test can
start on Home; `-UITestSeedLongSearchHistory` fills search history to its cap
so the Search landing page is taller than the screen (issue #244's regression
test); `-UITestDisableAnimations` and `-UITestDisableControlAutoHide`
remove the two timing races, and the first also freezes the sign-in journey's
ambient motion (`UITestHarness.freezesAmbientMotion`: the drifting background
and the scan radar redraw continuously otherwise). The hero carousel's timer
and the 3D tilt effect are switched off through the app's own `@AppStorage`
keys straight from `app.launchArguments`, with no app code involved at all —
and the first-run welcome the same way, `-onboarding.welcomeCompleted YES`,
which `UITestCase.launch` passes unless a journey asks for the welcome with
`skipsWelcome: false`.

**A stub server in-process** (`UITestStubURLProtocol` + `UITestFixtureLibrary`),
registered with `URLProtocol.registerClass`. That reaches `URLSession.shared`,
which is what `JellyfinAPIClient` runs on — the same mechanism `AppStateTests`
already uses, so no production refactor was needed. `RemoteImageLoader` and
`DownloadManager` build their own sessions and opt in via
`UITestHarness.decorate(_:)`. Fixtures are built as real `BaseItemDto` values
and encoded with `JellyfinJSON.encoder` rather than checked in as JSON, so a
DTO change is a compile error instead of a silent rot. Scenarios
(`-UITestScenario`) cover `standard`, `emptyLibrary`, `serverError`,
`unauthorized`, `offline`, `noDeletePermission`, `noPlaylistEditPermission`,
`slowLogoImage`, `slowSubtitleFonts`, `showWithoutEpisodes`,
`customHTTPPort`, `quickConnectDisabled`, `quickConnectExpiring`,
`quickConnectPending`, `hiddenUsers`, `slowScan` (the stub discovery
finds one server, then keeps scanning for two minutes — Find Your Server's
"Still searching…" state), `slowVideoDownload` (a download's stream held
for 10s, so the Downloads tab can be opened while it is in flight),
`slowPlaybackInfo` (`/PlaybackInfo` held for 30s, so the Apple TV player can
be closed while it is still loading), `slowBoxSet` (the box set's requests
held for 8s, so its Apple TV page can be left while it is still loading) and
`emptyBoxSet` (the box set lists no movies), `slowItems` (every list of
items held for 8s, for Home and a library loading slowly on the Apple TV),
`skipIntro` (every item has an intro from 0:00 to 83:20, so a resumed title
starts inside it and Skip Intro shows at once) and `earlyCredits` (every
episode's credits start at 0:05, so Next Up shows as soon as an episode plays
and counts down 10s).

Sign-in is built on `/Users/Public`, which the stub answers with two users:
the fixture user (`UITestFixtureIdentity.userID`, password
`UITestFixtureIdentity.password`) and a passwordless `Guest`
(`passwordlessUserID`), which the stub signs in with an empty password — the
one-tap path. `hiddenUsers` lists nobody, as a server with every user hidden
from its login screen does, which is what shows the plain username/password
form. `/Branding/Configuration` answers with a disclaimer carrying `<br/>` —
markup the app has to strip — and the splashscreen switched on, whose image is
the same generated PNG every artwork request gets.

Quick Connect needs a second client to approve the code, which no UI test has,
so the stub approves every code on its first poll — as though the user typed
it elsewhere during the app's real 5s poll interval, which is left alone
rather than shortened for tests. `quickConnectExpiring` answers the first
code's poll with Jellyfin's 404 (a code older than 10 minutes) and approves
the second, so "Get New Code" can recover; `quickConnectPending` never
approves, which is what holds the sheet still long enough to audit;
`quickConnectDisabled` answers `/QuickConnect/Enabled` with `false`. Codes are
numbered per run (`UITestFixtureIdentity.quickConnectCode(_:)`) so a journey
can tell the replacement code from the expired one. Approving codes from the
Account screen goes through `/QuickConnect/Authorize`, which the stub answers
by code: `UITestFixtureIdentity.quickConnectApprovableCode` succeeds,
`quickConnectUsedCode` gets the 500 Jellyfin gives an already-approved code,
anything else a 404, and every code a 401 under `quickConnectDisabled`.

Local-network server discovery is UDP, not HTTP, so the stub never sees it.
Under the harness `ServerSetupViewModel.defaultDiscovery()` swaps in
`UITestServerDiscovery`, which answers every scan — the one Find Your Server
starts by itself on arrival, so there is no scan button to tap first — with
the stub server
(`UITestFixtureIdentity.discoveredServerID`) — whatever network the runner is
on is never probed, and picking the result goes through the stub like a typed
address would. It also answers with the same stub server at an `https://`
address, and the stub fails every `https://` request with
`serverCertificateUntrusted`, which drives the plain-HTTP fallback;
`customHTTPPort` additionally refuses port 8096, so the fallback has to ask
for the port. A `TextField` inside a SwiftUI alert doesn't carry its
`.accessibilityIdentifier` (the alert's buttons do), so the screen object
selects the alert's only text field.

`showWithoutEpisodes` keeps the series and its seasons but answers every
`/Episodes` and `/Shows/NextUp` request empty — a show the server lists ahead
of any episode arriving (seen live). The show page then hides Play
(`AssetDetailViewModel.isShowWithoutPlayableEpisode`) and `SeasonEpisodeList`
says the season is empty.

`noDeletePermission` is the standard catalogue with `CanDelete` cleared on
every item and any `DELETE` refused — the signed-in user who simply isn't
allowed to delete anything, which is what gates `AssetActionsButton`'s delete
half. It exists as a *scenario* rather than a second set of fixtures so both
halves of the permission gate come from one catalogue. Note the toolbar item
doesn't vanish with it: `AssetActionsButton` always draws its `ellipsis`
overflow, so the journey opens it and asserts "Add to Playlist" is there and
`deleteButton` isn't.

`noPlaylistEditPermission` is the same idea for playlist membership edits:
the standard catalogue, but `GET /Playlists/{id}/Users/{userID}`
(`JellyfinAPIClient.playlistUserPermissions`) answers 404 for every playlist
and any playlist item add or removal is refused with 403. That gates two
things reading the same server answer — `PlaylistItemList`'s remove affordance
(`AssetDetailViewModel.canEditPlaylist`) and `AddToPlaylistSheet`'s
destination list (`JellyfinAPIClient.editablePlaylists`), which comes back
empty so the picker offers only "New Playlist". Creating one still succeeds
in this scenario, deliberately: Jellyfin's `POST /Playlists` is
`[Authorize]`-only, with no user-policy flag governing it at all.

Unlike `canDelete`, there's no server field this app can read to derive
playlist-edit permission locally (Jellyfin never exposes a playlist's
`OwnerUserId` to a client), so the stub mirrors the real permission-lookup
endpoint rather than just flipping a flag on the fixture DTOs. `standard` is
*not* a blanket "everything is editable" either — the `readOnlyPlaylist`
fixture answers 404 there too, so the picker's filter has something real to
reject in the normal case rather than trivially passing everything through.

`slowLogoImage` is the standard catalogue with one deliberate exception: a
`Logo` image response is held for `UITestStubURLProtocol.slowLogoImageDelay`
(18s, scheduled on a background queue — every other image resolves
immediately as usual) — long enough to outlast both `LogoImageView`'s own 1s
fallback-reveal delay and the navigation between the screens the journey
passes through; see that constant's doc comment for the two-sided window it
has to land in, and *never* reintroduce a blocking `Thread.sleep` here, which
stalls every request on that `URLSession` rather than just this one. It
exists because that delay is otherwise untestable at all:
`BackdropLogoOverlay` and `PlayerControlsOverlay`'s title row both hide the
real logo/fallback content from the accessibility tree (a VoiceOver fix —
see those types' own doc comments), so `HeroLogoFallbackUITests` observes
the timing through a dedicated test-only marker
(`A11yID.Media.heroLogoFallbackVisible`, `#if DEBUG`-gated in both views)
instead of the hidden content itself.

Deletion is also the one place the stub carries state: `DELETE /Items/{id}`
records the id, and every list route filters deleted ids out afterwards
(cascading to a show's seasons and episodes, as the real server does), so a
journey can assert the item is genuinely gone rather than that one request
returned 204. It's per-process, so each test's fresh launch starts clean. It
is also the only route matched on HTTP *method* as well as path — without
that, a `DELETE` would fall through to the item-lookup route and be answered
with a JSON body.

Downloads are the one path where the stub has to serve *real media bytes*
rather than JSON, and they can't be arbitrary ones:
`DownloadManager.validationFailureReason` opens every finished download with
`AVURLAsset` and fails it as unverifiable if the duration won't load — the
check that exists because a crashed transcode still closes as a clean HTTP
200. So `UITestStubURLProtocol.syntheticMP4(durationSeconds:)`
hand-assembles a ~600-byte MP4 declaring the fixture item's own runtime.
Two things about it that are not guessable: the duration has to live in the
*sample table*, because `AVAsset` derives duration from the longest track
and a track with no samples is zero-length however long its `mvhd` claims to
be (measured — the header-only version loaded fine and reported `0`); and
`stco`'s chunk offset is an absolute file offset, so `moov` is built twice,
the second pass byte-identical in size to the first. Downloads also drop
from a background `URLSessionConfiguration` to a default one under
`-UITestMode` (`DownloadManager.makeBackgroundConfiguration`) — a background
session runs its transfers in a separate system daemon that `URLProtocol`
cannot reach at all. That is a real divergence, and the reason downloads are
covered only as far as "bytes land and the row settles": backgrounding,
suspension and OS-relaunch resumption stay device-only checks.

**A fake playback engine**, via `PlaybackEngineFactory`. With no AetherEngine
there is no video surface, so `PlayerControlsOverlay` is plain SwiftUI that
XCUITest can drive. What this does *not* cover is decode, HDR, transcode and
seek — those still need real media on a real device.

Its `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` do track the selection
(they were once no-ops), because the authored-ASS path hangs off
`onSubtitleTrackChange` and would otherwise be unreachable from a UI test at
all. `selectSubtitleTrack(id:)` also publishes a cue, which is what
`SubtitleOverlayView`'s own (non-libass) path renders — every SubRip and
WebVTT track, and an ASS track with Subtitle Styling off. Without it that path
paints nothing under the harness, so a journey could only ever assert the
*absence* of a libass frame, which passes just as happily on a bug that drops
the track altogether. Its text differs from the styled fixture's on purpose
(`UITestFixtureIdentity.plainSubtitleCueText`), so a test can tell the two
renderers apart rather than inferring one from the other's absence. Its canned subtitle tracks include one with `codec: "ass"`, paired with
an embedded ASS `MediaStream` in the fixture whose `index` deliberately does
*not* match that track's id — the app maps the two by ordinal, and a fixture
where they happened to agree would pass even if that mapping were broken.

libass itself is NOT faked: `StyledSubtitleJourneyTests` drives the real
renderer over a real script (`UITestStubURLProtocol.assScript`). The script
has to be real — arbitrary bytes parse to zero events and render nothing,
which is indistinguishable from the feature being broken. It carries two
always-on cues, one bottom-aligned and one `\an8`, so a journey can check
that a top-aligned sign stays on the picture rather than being relocated into
the letterbox bar above it: that guard asserts on the element's `frame`, and
was confirmed to fail against the pre-fix geometry (y 7 against a floor of
150) rather than merely passing against the fixed one. Because libass
composites a whole frame into one bitmap there is no `Text` to read, so the
overlay's accessibility label (the cue text, which is also what VoiceOver
gets) is what the journey asserts on. Note the stub matches `/Subtitles/`
*before* `/Videos/`: a subtitle URL contains both, and the other order
answers every subtitle request with a synthetic MP4 — which a download
happily writes to disk, and which the styled path can only read as "this
track has no script".

`StyledSubtitleJourneyTests` also covers the **Subtitle Styling** setting
(Profile → Playback → Advanced), forced through `UserDefaults`' argument domain
via `launch(extraArguments:)` rather than by driving the settings screen — the
Advanced screen sits behind an iPhone/iPad layout fork `ProfileScreen`
deliberately doesn't absorb, and what the journey is about is the player's
behaviour, not how the switch was flipped. Two halves, and both matter: off,
the ASS track must render *unstyled* rather than not at all; left alone, it
must render styled, which states the on-by-default as a behaviour rather than
only as a constant. `ASSSubtitleMappingTests` covers the read itself, and the
font-source rule (`assFonts(engineAttachments:fetched:)`) alongside it — in
particular that an unset key means on, since `UserDefaults.bool(forKey:)`
reports `false` for a key never written and reading it directly would ship the
feature off for everyone who never opened Settings.

It covers the **font attachments** too. The fixture media source declares one
font and one piece of cover art, and `PreviewPlaybackEngine` reports no
attachments of its own, so *every* journey in that file goes through the fetch
path — which is exactly the production shape for the two routes it serves, a
server-side transcode and offline playback, where AetherEngine has nothing to
report either. The stub serves stand-in bytes rather than a real face:
`CTFontManager` refuses them, same as a container whose fonts the device can't
use, and what a journey can actually prove is the fetch's effect on the
subtitle, not the typography. Registration itself is verified on a real device
against a retail MKV (see `CLAUDE.md`'s Subtitles section).

The one behaviour only a journey can pin is that **fonts don't gate the
script**. The `.slowSubtitleFonts` scenario holds the attachment response for
two minutes against a 15s assertion budget, so a build that waited for the
fonts before handing the script to libass cannot pass by finishing early — and
that was confirmed by mutating the code to join on the fetch and watching the
journey fail, not merely by watching it pass as written. Inside that budget it
doubles as the "the font fetch failed outright" case, since no faces arrive
either way. Note the stub answers `/Attachments/` from `startLoading` rather
than the synchronous path switch (the delay needs `asyncAfter`, never
`Thread.sleep` — see `.slowLogoImage` for what blocking that serial queue
costs) and ahead of the scenario gate, for the same reason images are: failing
a decoration under `.serverError` only obscures what that scenario is about.

### Where they run in CI

Every UI-test run goes through one reusable workflow,
`.github/workflows/ui-tests.yml`, which owns the device/OS matrix: an
**iPhone 16** and an **iPad (A16)**, each on

| iOS | Why | PR smoke | Full plan: PR into `stable`, nightly, release |
| --- | --- | --- | --- |
| 26.5 | Latest runtime for the pinned Xcode (26.6) | ✓ | ✓ |
| 18.6 | Previous major *and* the deployment floor | | ✓ |

Apple went from iOS 18 straight to 26, so on Xcode 26 the previous major and
the floor are the same version. iOS 18 is the environment that matters most
here: it is the only place the pre-26 branch of any `#available(iOS 26, *)`
check runs. No runner image carries both versions, and Xcode won't download
an iOS 18 runtime at all ("not available for download", for every 18.x), so
each version brings its own image and Xcode: 26.5 on `macos-26` with Xcode
26.6 (the release toolchain), 18.6 on `macos-15` with Xcode 26.3, the newest
that image has. The iOS 18 leg is testing the OS, not the toolchain.

iOS 18 differs from 26 in ways that have already bitten (#259), so write
journeys that hold on both: the navigation back button has no `BackButton`
identifier on 18 (use `app.navigationBackButton`), XCUITest there won't
scroll a horizontal row to an off-screen control and `isHittable` throws for
one (judge by frame, as `CollectionScreen.openFilter` does), and iPad split
views overlay the sidebar in portrait unless styled `.balanced`. Locally,
Apple's downloads site offers an iOS 18.2 simulator runtime (`xcrun simctl
runtime add <dmg>`); iPad (A16) needs 18.3, so use iPad (10th generation),
the same 820×1180pt screen.

The simulator is the image's own device of that model and version when the
image has one, and a newly created one otherwise (iPhone 16 on iOS 26.5).

The models are the same on both versions, so a failure on only one OS can't
be a screen-size difference; the iPhone is a 16 because the 17 can't run
iOS 18. Each environment runs on its own runner with `fail-fast: false`, so
every one reports, and a failed one uploads its `.xcresult` as
`ui-test-results-<plan>-<device>-iOS-<version>`.

The Apple TV suite has its own reusable workflow,
`.github/workflows/tv-ui-tests.yml`: an Apple TV 4K (3rd generation) with
Xcode 27.1, on GitHub's `xcode-27` image (macOS 27, a preview image) rather
than `macos-26`, one job per tvOS version (`tvos-versions`). It runs
`TVUITests-Smoke` on tvOS 27.0 on every PR and `TVUITests` on tvOS 27.0
nightly and on PRs into `stable`; release.yml doesn't run it while the Apple
TV app isn't shipped. A failed job uploads
`tv-ui-test-results-<plan>-tvOS-<version>`.

**Why not tvOS 26.5, and not `macos-26`** (#319, 2026-10-09): on tvOS 26.x
in CI, the app's accessibility tree never shows a page the shell opens after
launch. The screen recording in the `.xcresult` shows the detail page,
library or Search open within the wait, but every element tree XCUITest
reads still lists Home, so the journeys that open one fail (four of the
seven smoke journeys). It isn't SwiftUI animation, XCTest's in-app query
evaluation (`XCTDisableRemoteQueryEvaluation`), the runner image's own
simulator, the host (it fails on both `macos-26` and `xcode-27`), the Xcode
(26.6 and 27.1), or a missing `UIAccessibility` screen-changed notification
from the shell; each was tried. tvOS 27.0 passes on the same runner, and
tvOS 26.5 passes on a Mac (macOS 27, Xcode 26.6's tools). So tvOS 26.5, the
deployment floor's major, runs nightly only, as `tvOS floor smoke tests` with
`allow-failure`: it reports without turning the nightly red, and the image
has no 26.5 runtime, so the job downloads one (3.76 GB, about five minutes).
When it passes again, make it a PR check.

"tvOS UI smoke tests / Apple TV 4K, tvOS 27.0" is meant to be required by
both rulesets; its name embeds the version, so a version change means
updating them in the same breath.

A release doesn't sign or upload anything until every environment has
passed. Because nightly and release call the same workflow, dispatching
"Nightly UI tests" on a branch (`gh workflow run nightly-ui-tests.yml --ref
<branch>`) is a dry run of a release's UI stage.

A PR into `stable` runs the full plan too (`pr-checks.yml`'s `ui-full` job),
because `stable`'s ruleset requires the four `Full UI tests / <device>, iOS
<version>` checks. The job is named `Full UI tests`, like the nightly's, so
the names match. A nightly dispatched on the PR's branch reports checks of
those names on the head commit, but GitHub doesn't count them towards the PR
(found promoting v1.1.0, #290), so don't rely on it to unblock one.

When CI moves to a new Xcode, the Xcode version (`setup-ios-project`), the
runner labels and `ui-tests.yml`'s version list change together.
From Xcode 27, iOS 26 becomes the previous major and 18 stays as the floor,
so the full matrix grows to three versions. Changing the latest version or a
device also renames the two smoke checks (`UI smoke tests / iPhone, iOS
26.5` and `UI smoke tests / iPad, iOS 26.5`), which both branch rulesets
require by name, and the four `Full UI tests / …` checks `stable`'s ruleset
requires — update them in the same change.

### Selectors

Tests address elements by `A11yID` (`Shared/Accessibility/`), which is
compiled into *both* targets, so a renamed identifier is a compile error
rather than a timeout. Never select on `.accessibilityLabel`: those are
`String(localized:)` values and would break on the first translation.

Five hard-won rules, the first two documented at length in `A11yID` itself:

- **Identify controls, not screen roots.** `.accessibilityIdentifier` on a
  container sometimes scopes to that container and sometimes propagates down
  and *overwrites* its descendants' own identifiers. Measured both ways here.
- **The tab bar differs by device.** iPad keeps the identifier set inside
  `.tabItem`; iPhone converts the item into a UIKit `UITabBarItem` and drops
  it. The `TabBar` screen object falls back to tab *order* — not label, which
  would be localized.
- **A media tile's identifier is rarely unique on screen, and not every
  duplicate is safe to tap.** The same item can legitimately appear twice
  (a rail *and* the hero carousel); `Screen.onScreenMatch(identifier:in:)`
  picks the copy XCUITest reports as actually within the screen's width.
  Two real, measured failure modes this exists for: the hero carousel's
  own off-screen paging duplicates (a full screen-width outside either
  edge) synthesize a tap at whatever's really on screen at that point
  instead — silently landing on a different item's detail page, no error —
  and `.isHittable` doesn't catch it either. A `LazyHStack` library-rail
  card genuinely off past the initial viewport (the later cards on
  iPhone's narrower width) instead fails outright with "Activation point
  invalid" rather than the auto-scroll a normal off-screen element gets;
  `HomeScreen.openLibrary(_:)` does one bounded swipe on the rail first.
  A third, for a tile below the fold: `tap()` scrolls to it first, and once,
  on a loaded CI runner, the touch that followed did nothing — right poster,
  settled page, no push. `HomeScreen.openItem(_:)` therefore taps through
  `XCUIElement.tapToLeave()`, which taps again only while the tile is still
  on screen and hittable. A pushed page takes Home's tiles out of the tree,
  so a retry can never land on the page the first tap opened.
- **`.accessibilityElement(children: .ignore)` on a row makes it report as
  `Other`, not `Button`** — so `app.buttons[id]` silently never resolves
  even though the identifier is right there in the tree, with the real
  `Button` nested one level below carrying no identifier of its own.
  Measured on `PlayerControlsOverlay`'s track-picker rows; `PlayerScreen`
  queries them via `app.descendants(matching: .any)[id]` instead, which
  taps fine. `ChapterPickerOverlay`'s rows are the counter-example — they
  add `.isButton` back via `.accessibilityAddTraits`, and so *do* resolve
  as `Button`. Prefer `.descendants(matching: .any)` for anything carrying
  `.ignore`.
- **A subscript lookup matches on label as readily as on identifier**, so
  `app.buttons["Sign Out"]` finds both a confirmation dialog's button and
  the row that raised it — giving "Multiple matching elements found" even
  though the row has an explicit, different identifier. Scope dialog
  buttons to their container (`app.sheets.buttons["Sign Out"]`, as
  `ProfileScreen.signOut()` does). Adding an identifier to a control does
  not stop its *label* from matching.

When something can't be found, dump `XCUIApplication.debugDescription` and
look at the real tree. Every one of the rules above came from doing that;
none of them were guessable.

### Accessibility audits

`AccessibilityAuditTests` runs `performAccessibilityAudit()` over every
screen the app can reach — the welcome, server setup and its address sheet,
the sign-in grid, its password step, the "Other" sheet and the fallback form
included. These are the cheapest coverage here — about ten
lines per screen, and the only tests in the suite that can fail for a reason
nobody thought to write an assertion about.

**They gate on structural issues only**, and the app passes those clean:
`.elementDetection`, `.hitRegion`, `.sufficientElementDescription` and
`.trait`. (`.action` and `.parentChild` are in the header but are macOS-only
— they do not compile against the iOS SDK.) These are the "this element is
wrong" checks: an unlabeled control, a label that is not human-readable, a
trait contradicting what the element does. A regression here is a bug on any
reading.

Two real bugs turned up the first time it ran, both now fixed:

- **`ServerSetupView`'s header icon announced "server.rack".** A decorative
  `Image(systemName:)` with no `.accessibilityHidden(true)` falls back to the
  SF Symbol's own name, so VoiceOver read the literal string out.
- **The player had no accessible name for what was playing.** When an item
  has a logo, `PlayerControlsOverlay.titleRow` renders it *instead of* the
  title text — and `LogoImageView`/`LocalFileImage` produce a bare `Image`
  with no label, so the one thing that row exists to say was unavailable.
  Fixed with the same `.ignore` + explicit-label shape `HeroRailView` and
  `ProfileView` already use.

**What it deliberately does not gate on**, measured across the twelve screens
that existed when the set was chosen
(2026-09-06): `.contrast` (36 issues), `.dynamicType` (64) and
`.textClipped` (45) — 145 of the 154 that `.all` reports. These are not
stray mistakes. They are consequences of deliberate, app-wide design
choices: the secondary caption colour behind every "2019 · 1h 35m" subtitle,
and fixed-size poster/landscape tiles whose one-line captions cannot grow
with Dynamic Type without reflowing every grid in the app. Turning them on
today would mean 145 suppressions, which is not a gate — it is a rubber
stamp. Changing the underlying design is real work with real visual
trade-offs and deserves its own change, argued on its merits.

That split is the point, and it is worth preserving: **this suite refuses to
report green on something it is not actually checking.** If you widen
`auditedTypes`, fix the findings rather than suppressing them.

Four suppressions exist, each scoped to a kind of element rather than to an
audit type alone (see `isKnownAcceptable`). Two are the system keyboard, which
the audit reaches whenever a screen autofocuses a text field: any `.key`
element (from the iOS 27 runtime the URL keyboard's ".co.uk" key fails as "not
human-readable" on Server Setup, but only when the software keyboard is up,
which depends on the simulator's state rather than the app), and the QuickType
prediction cell on the New Playlist form. The other two are UIKit's own 20.5pt
"Clear text" button inside `.searchable`, which this app does not own and
cannot resize; and the hit-region minimum on non-interactive `StaticText`
metadata lines ("Genres: Drama"), where a 44pt floor would insert large dead
gaps between rows purely to satisfy a rule about touch targets.

One more allowance is per-audit rather than global: `auditCurrentScreen(underModal: true)`,
for audits taken with something modal up that leaves the screen behind it
visible but dimmed. That covers the two Server Setup audits taken under a
system alert, plus the login password step (a popover on iPad) and the Add to
Playlist picker and New Playlist form (form sheets on iPad, which don't cover
the screen the way the iPhone's full-height sheet does). The audit still sees
the dimmed screen's text, but iOS rightly takes it out of the accessibility
tree while the modal is up. That reports as one `.elementDetection`
"Potentially inaccessible text" issue with no element attached, and only that
exact shape is let through; everything in the modal itself is still audited.
The iPad cases failed every night for weeks unnoticed: the nightly job piped
`xcodebuild` into `xcbeautify` without `pipefail`, so the run reported
success regardless. That was fixed in PR #258.

### Adding a journey

1. Put it in `DionysusPlayerUITests/Journeys/`, and put its selectors in a
   screen object in `Screens/` — tests should read as user intent, with
   every selector defined once.
2. Add any new identifier to `A11yID` **in the same change that applies it to
   a view**. A constant nothing uses looks like an available selector and
   silently never resolves.
3. Launch through `UITestCase.launch(...)`, never by building
   `XCUIApplication` by hand — that is where the flake mitigations live.
4. New files need `xcodegen generate`.
5. If it belongs in the PR gate, add it to `TestPlans/UITests-Smoke.xctestplan`
   as well. Keep that plan small; its job is fast feedback, not coverage.

**Check a new test actually fails.** Break the thing it covers on purpose and
watch it go red. This is not ceremony: `testOpeningAnItemFromHome` passed with
`PosterCard`'s destination deliberately broken, because `.firstMatch` resolved
to the hero carousel's tile instead — the poster rails were never being
tapped at all. `testOpeningAnItemFromACollectionGrid` exists because of that.

**An intermittent failure may be a crash, not flake.** The tell is an
`app.debugDescription` that comes back *empty* (`Query chain: Find: Target
Application`) alongside "Restarting after unexpected exit, crash, or test
timeout" in the log — the app process died, so there was no tree to dump and
no element to find. Check `~/Library/Logs/DiagnosticReports/` for a
`Dionysus-*.ips` before touching the test; its stack names the trapping
accessor directly, which the XCUITest log cannot.

That is how this suite found its first real bug:
`DownloadsJourneyTests.testDeletingAllDownloadsReturnsToTheEmptyState`
failed 2 runs in 9 on iPad, and the crash logs pointed at
`DownloadedItem.metadata.getter` reached from `DownloadsView.gridSubtitle(_:)`
— bulk delete trapping in SwiftData because `DownloadsRow` held the live
model. Fixed by snapshotting the row's display fields
(`DownloadsRow.StandaloneItem`); 10/10 clean afterwards. Worth knowing the
shape of, because a rerun-until-green habit would have buried it.

**The same message after every failure means the retry was lost.** In Xcode
26, a Swift UI test with `continueAfterFailure = false` and an async `setUp`,
`tearDown` or test method has its runner terminated after its first failure;
xcodebuild logs "Restarting after unexpected exit…" and carries on at the next
test, so the plan's `retryOnFailure` never runs (Apple's known issue
108565878, [forum thread 809989](https://developer.apple.com/forums/thread/809989)).
Until 2026-10-09 `UITestCase` overrode the async variants, so every iOS UI
failure in CI was final, a one-off launch timeout included: four of the five
nightlies that finished between 4 and 9 October failed on the iPad on iOS
26.5, each on one test, a different one each night, with every other test
passing.
The Apple TV suite's synchronous `setUp` retried all along. Keep both base
classes' overrides synchronous, and don't make a test method `async`. A retried
failure shows as "Iteration 2 of 3" in the runner's log.

## Adding a unit test

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
