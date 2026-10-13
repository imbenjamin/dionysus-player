# Testing

How this repo is tested: the suites and where they run, how to run them, the
UI-test harness, the rules that keep the journeys reliable, and what is still
checked by hand. What each test pins is in the test itself (its name and doc
comment); the index at the end says where to look.

## The suites

| Target | Plan | What it is | Where it runs |
| --- | --- | --- | --- |
| `DionysusPlayerTests` | `UnitTests` | iOS unit tests (the scheme's default plan) | Every PR, every release |
| `DionysusPlayerUITests` | `UITests-Smoke` | Seven iOS journeys and the keychain-reset check | Every PR, iPhone and iPad, latest iOS |
| | `UITests-Full` | Every iOS journey and audit | Nightly, PRs into `stable`, releases; iPhone and iPad on every supported iOS |
| `DionysusTVTests` | `TVUnitTests` | The Apple TV app's own tests, plus the shared ones run on tvOS | Every PR |
| `DionysusTVUITests` | `TVUITests-Smoke` | Seven Apple TV journeys: first launch to sign-in, Home, a detail page from Home and from a library, Search, the player | Every PR, tvOS 27.0; nightly on tvOS 26.5 as an allowed failure |
| | `TVUITests` | Every Apple TV journey and audit | Nightly and PRs into `stable`, tvOS 27.0 |

Unit tests run in-process with no real network and take seconds. UI tests
(XCUITest) drive the real app in the Simulator against an in-process stub
server and a fake playback engine. Test targets `@testable import Dionysus`:
the module is named after `PRODUCT_NAME` (`Dionysus`), not the target.

## Running the tests

In Xcode: `xcodegen generate` if `project.yml` changed, open
`DionysusPlayer.xcodeproj`, pick the scheme, Cmd+U (or the diamond beside one
test). From the CLI:

```sh
# iOS: UnitTests is the default; name a UI plan with -testPlan
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -testPlan UITests-Smoke -destination 'platform=iOS Simulator,name=iPhone 17'

# Apple TV
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Use whatever `xcrun simctl list devices available` shows. Check Apple TV
journeys on a tvOS 26 Simulator as well as 27: 26.0 is the floor and focus
behaves differently there.

**Before a full Apple TV UI run, run one journey on its own as a warm-up**,
as CI does ("The first test's warm-up", below), and ignore how it ends:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -only-testing:DionysusTVUITests/CollectionGridJourneyTests/test_tile_opensItsDetailPage_andMenuReturnsToIt
```

Without it the plan's first test, `AccessibilityAuditTests.test_boxSet`, can
fail at `TVShellJourney.pressDown` on a tvOS 26.5 Simulator with nothing wrong
(2026-10-13). The recording shows Collections focused, but XCUITest's tree
keeps the collapsed sidebar's attributes (every row Disabled, none focused),
so the loop presses on to Playlists. Whichever test runs first takes it:
`test_playlist` failed the same way when run first, and `test_boxSet` passed
after it.

## Unit tests

They target the layer with the logic: models, the networking client, view
models and the pure decision helpers views call (`Core/` and
`Features/*ViewModel.swift`, plus tvOS's own helpers). Views as views have no
snapshot tests: they are thin over their view models, and the UI suites catch
layout regressions end to end; revisit `swift-snapshot-testing` if visual
regressions start slipping through.

### How network calls are faked

`JellyfinAPIClient` is an actor that owns a concrete `URLSession`, not a
protocol, so there's no fake client: `Support/MockURLProtocol.swift` is a
`URLProtocol` stub. Make a session with `MockURLProtocol.makeSession()`, inject
it into a real client, and script `MockURLProtocol.requestHandler`. What's
under test is the client's real request building and decoding. View model
tests reuse it, since view models take an already-built client. Three things
that aren't guessable:

- **`URLSession`'s async `data(for:)` moves a request's body into
  `httpBodyStream`** before a custom `URLProtocol` sees it, so
  `request.httpBody` reads `nil`; `URLRequest.capturedHTTPBody` drains
  whichever is populated.
- **`AppState` and `ServerSetupViewModel` build their own client on
  `URLSession.shared`**, so their tests register `MockURLProtocol` process-wide
  (`URLProtocol.registerClass`; see `AppStateTests`).
- **The async polling helper `waitUntil` is `@MainActor`**, to match its
  callers; otherwise Swift 6 flags the closure as an unsafe cross-actor send.

`project.yml` sets `TEST_HOST`/`BUNDLE_LOADER` explicitly: XcodeGen's inferred
host assumed the bundle was named after the target.

### The shared tests on tvOS

`DionysusTVTests` holds the Apple TV app's own tests and also compiles a
subset of `DionysusPlayerTests` against the tvOS build of the shared code:
everything testing `Core/`, `AppState` and the shared view models, minus
Downloads. The list is `project.yml`'s `includes` on that target. A test of
iOS-only behaviour stays out of the list with a comment saying why; a test
that only partly touches Downloads wraps that part in `#if DOWNLOADS`. Never
change an assertion to make it pass on tvOS.

On tvOS the server configuration lives in the keychain every Apple TV user
shares, not in `UserDefaults`, so a shared test that saves a server must
delete `server.configuration` with `scope: .allUsers` in its `tearDown`
(`ServerSessionStoreTests`, `AppStateTests`, `LoginViewModelTests`), or it
leaks into the next test on tvOS only. `TVAppLaunchTests` checks what the
app's own launch sets up, since the test host runs `DionysusTVApp.init`.

### Adding a unit test

1. Put it in the matching folder: `DionysusPlayerTests/` mirrors the app's
   paths (`Features/Foo/FooViewModel.swift` →
   `DionysusPlayerTests/Features/Foo/FooViewModelTests.swift`); Apple TV-only
   tests go in `DionysusTVTests/`.
2. New files need `xcodegen generate` (each target's `sources:` covers its
   folder). A shared test that should also run on tvOS goes into the
   `DionysusTVTests` target's `includes` in `project.yml`.
3. Anything that talks to `JellyfinAPIClient` uses `MockURLProtocol`, never a
   real server.
4. Prefer a pure helper with a unit test over logic inside a view's `body`.

## UI tests

The regressions this project actually shipped were layout and navigation
ones (the rotation-lock break, the Home→Detail push, a `LazyHStack` layout
hang), none reachable from a view-model test. So both apps have an XCUITest
suite, and three things make it deterministic. All are `#if DEBUG` and absent
from a Release binary (`nm -a` on a Release build finds none).

### The launch-argument harness

`Core/UITestSupport/UITestHarness.swift` runs from the app's `init()`, before
`AppState` exists, since `ServerSessionStore` reads `UserDefaults` and the
Keychain as it's made.

- `-UITestResetState` clears both, the shared tvOS keychain and the tvOS
  session settings included. The Keychain outlives the app's container, so
  without it one test's sign-in seeds the next test's "first launch".
- `-UITestSeedSession` plants a session, so a test can start on Home.
- `-UITestDisableAnimations` and `-UITestDisableControlAutoHide` remove the two
  timing races; the first also freezes ambient motion
  (`UITestHarness.freezesAmbientMotion`), which otherwise keeps the tree
  moving.
- `-UITestScenario <name>` picks the stub's behaviour (below).
- `-UITestSeedLongSearchHistory` fills Search's history to its cap (#244).
- `launch(resetsState: false)` relaunches without the reset, to check what
  survives a relaunch; `launch(extraArguments:)` can force a setting through
  `UserDefaults`' argument domain instead of driving the settings screen.
- `-UITestAccessibleTransport YES` forces the Apple TV player's accessible
  transport, since XCUITest can run neither VoiceOver nor Switch Control.
- The hero's timer, the 3D tilt and the welcome (`-onboarding.welcomeCompleted
  YES`) are switched off through the app's own `@AppStorage` keys straight from
  the launch arguments. `UITestCase.launch` and `TVUITestCase.launch` skip the
  welcome unless a journey passes `skipsWelcome: false`.

### The stub server

`UITestStubURLProtocol` and `UITestFixtureLibrary`, registered with
`URLProtocol.registerClass`. That reaches `URLSession.shared`, which
`JellyfinAPIClient` runs on; `RemoteImageLoader` and `DownloadManager` build
their own sessions and opt in through `UITestHarness.decorate(_:)`. Fixtures
are real `BaseItemDto` values encoded with `JellyfinJSON.encoder`, not checked-in
JSON, so a DTO change is a compile error rather than silent rot.

- **Sign-in**: `/Users/Public` lists the fixture user
  (`UITestFixtureIdentity.userID`, password `UITestFixtureIdentity.password`)
  and a passwordless `Guest` (`passwordlessUserID`, signed in with an empty
  password). `/Branding/Configuration` carries a disclaimer with `<br/>` and
  the splashscreen switched on.
- **Quick Connect** needs a second client to approve the code, so the stub
  approves every code on its first poll; the app's real 5s poll interval is
  left alone. Codes are numbered per run (`quickConnectCode(_:)`), so a
  journey can tell a replacement from the expired one. Approving from the
  Account screen goes through `/QuickConnect/Authorize`:
  `quickConnectApprovableCode` succeeds, `quickConnectUsedCode` gets Jellyfin's
  500 for an already-approved code, anything else 404, and every code 401
  under `quickConnectDisabled`.
- **Discovery** is UDP, which the stub never sees, so under the harness
  `ServerSetupViewModel.defaultDiscovery()` is `UITestServerDiscovery`: every
  scan answers with the stub server, at an `http://` and an `https://`
  address. The stub fails every `https://` request with
  `serverCertificateUntrusted`, which drives the plain-HTTP fallback.
- **State it carries**: deletion (`DELETE /Items/{id}` records the id and every
  list filters it out afterwards, cascading to a show's seasons and episodes;
  the only route matched on method as well as path) and watched changes
  (`watchedOverrides`). Both are per process, so each launch starts clean.
- **Real media bytes for downloads**: `DownloadManager` opens every finished
  file with `AVURLAsset` and fails it if the duration won't load, so
  `syntheticMP4(durationSeconds:)` hand-assembles a ~600-byte MP4. The
  duration must live in the sample table (a track with no samples is
  zero-length whatever `mvhd` says, measured), and `stco` holds an absolute
  offset, so `moov` is built twice. Under `-UITestMode` downloads use a default
  session instead of a background one, which runs in a daemon `URLProtocol`
  can't reach; backgrounding and relaunch resumption stay device-only.
- **Route order matters**: `/Subtitles/` is matched before `/Videos/` (a
  subtitle URL contains both), and `/Attachments/` and images are answered
  ahead of the scenario gate, since failing a decoration under `serverError`
  only obscures what that scenario is about.
- **A delay never blocks the queue**: held responses use `asyncAfter`, never
  `Thread.sleep`, which stalls every request on that session.

**Scenarios** (`-UITestScenario`, documented case by case in
`UITestConfiguration.swift`):

| Scenario | What changes |
| --- | --- |
| `standard` | Two libraries, movies, a two-season show, a box set, a playlist |
| `emptyLibrary` | Every list is empty |
| `serverError` | Browse endpoints 500; sign-in still works |
| `unauthorized` | Browse endpoints 401 once per path, then succeed (silent re-auth) |
| `offline` | Every request fails as unreachable |
| `noDeletePermission` | `CanDelete: false` everywhere, `DELETE` refused |
| `folderlessSeasons` | Made-up seasons, so Delete Season goes episode by episode |
| `noPlaylistEditPermission` | Every playlist's permission lookup 404s; adds and removals 403 |
| `slowLogoImage` | A hero logo held past the fallback's reveal delay |
| `slowSubtitleFonts` | The font attachments held, to prove fonts don't gate the script |
| `showWithoutEpisodes` | The show's seasons with no episodes and no Next Up |
| `customHTTPPort` | Nothing answers on 8096, so the HTTP fallback asks for the port |
| `quickConnectDisabled` / `quickConnectExpiring` / `quickConnectPending` | Quick Connect off; the first code expires; no code is ever approved |
| `hiddenUsers` | `/Users/Public` lists nobody, so sign-in is a username/password form |
| `slowScan` | Discovery finds one server, then keeps scanning for two minutes |
| `slowVideoDownload` | A download's stream held, so the tab can be opened mid-download |
| `slowPlaybackInfo` | `/PlaybackInfo` held, so the Apple TV player can close while loading |
| `failingDetail` / `failingHome` / `failingLibrary` | `movie-03`'s item, Home's hero query, or the Movies listing answers 500 |
| `slowBoxSet` / `emptyBoxSet` | The box set held, or empty |
| `slowItems` | Every list of items held (Home and a library loading on Apple TV) |
| `largeCast` | Ten people on a movie, so Cast & Crew runs far past the action row |
| `noBackdrop` | Items fetched on their own have no backdrop |
| `missingTileArtwork` | The part-watched movie's artwork 404s |
| `manyGenres` | Twelve genres, so the Genre list scrolls |
| `manyLibraries` | Seven libraries incl. Music, so the Apple TV sidebar folds them |
| `manyUsers` | Six users, more than Who's Watching? fits in a row |
| `librariesFailAtFirst` | `/Views` 500s for five seconds, then succeeds |
| `thinDynamicRails` | Home's dynamic rails nearly all too thin, so it keeps loading |
| `skipIntro` / `earlyCredits` | An intro from 0:00 to 83:20; credits from 0:05 (Next Up at once) |

### The fake playback engine

`PlaybackEngineFactory` hands the player `PreviewPlaybackEngine` (with its
clock running) under the harness, so there's no video surface and the
transport is plain SwiftUI XCUITest can drive. Decode, HDR, transcode and
seek stay device checks.

- Its track selection is real (`selectAudioTrack`/`selectSubtitleTrack`),
  since the styled-subtitle path hangs off `onSubtitleTrackChange`.
  `selectSubtitleTrack` also publishes a cue for `SubtitleOverlayView`'s own
  path, with text that differs from the styled fixture's
  (`plainSubtitleCueText`), so a journey tells the two renderers apart rather
  than inferring one from the other's absence.
- Its canned ASS track is paired with an embedded ASS `MediaStream` whose
  `index` deliberately doesn't match the track's id, so the ordinal mapping is
  really exercised.
- It reports no font attachments, so every styled-subtitle journey takes the
  fetch path (the transcode and offline shape).
- **libass is not faked**: `StyledSubtitleJourneyTests` renders a real script
  (`UITestStubURLProtocol.assScript`; arbitrary bytes parse to zero events). It
  has a bottom-aligned and an `\an8` cue, so a journey checks a top-aligned
  sign stays on the picture by its frame (it failed against the old geometry,
  y 7 against a floor of 150). libass composites one bitmap, so journeys assert
  on the overlay's accessibility label, the cue text VoiceOver gets.
- `togglePlayPause()` really toggles: when it did nothing, every journey that
  pressed Play/Pause tested nothing.

### Selectors

Tests address elements by `A11yID` (`Shared/Accessibility/`), compiled into
both the app and the tests, so a renamed identifier is a compile error, not a
timeout. **Never select on an accessibility label**: labels are localized.
When something can't be found, dump `XCUIApplication.debugDescription` and
read the real tree; every rule below came from doing that.

- **Identify controls, not screen roots.** An identifier on a container
  sometimes scopes to it and sometimes overwrites every descendant's own
  (measured both ways; documented in `A11yID`).
- **iPhone's tab bar drops the identifier** set inside `.tabItem` (it becomes
  a `UITabBarItem`); iPad keeps it. The `TabBar` screen object falls back to
  tab order.
- **A media tile's identifier is rarely unique on screen, and not every copy
  is safe to tap.** The hero carousel's off-screen paging copies take a
  synthesized tap at whatever is really there (a different item's page, no
  error, `isHittable` fooled too); `Screen.onScreenMatch(identifier:in:)`
  picks the copy within the screen's width. A `LazyHStack` card past the first
  viewport fails with "Activation point invalid", so
  `HomeScreen.openLibrary(_:)` swipes the rail once first. A tile below the
  fold once took no tap on a loaded runner, so `HomeScreen.openItem(_:)` taps
  through `XCUIElement.tapToLeave()`, which retries only while the tile is
  still on screen.
- **`.accessibilityElement(children: .ignore)` makes a row report as `Other`,
  not `Button`**, so `app.buttons[id]` never resolves; query
  `app.descendants(matching: .any)[id]` (or add `.isButton` back, as
  `ChapterPickerOverlay` does). The same goes for tvOS menu rows and an
  adjustable SwiftUI element.
- **A subscript matches labels as readily as identifiers**:
  `app.buttons["Sign Out"]` finds both a dialog's button and the row that
  raised it. Scope dialog buttons to their container
  (`app.sheets.buttons["Sign Out"]`).
- **A `TextField` in a SwiftUI alert loses its identifier** (the alert's
  buttons keep theirs); select the alert's only text field. On tvOS a
  `.confirmationDialog`'s buttons lose theirs too, so the app's questions are
  covers of its own.
- **iOS 18 differs from 26** (#259): the back button has no `BackButton`
  identifier (use `app.navigationBackButton`); XCUITest won't scroll a
  horizontal row to an off-screen control and `isHittable` throws for one
  (judge by frame, as `CollectionScreen.openFilter` does); iPad split views
  overlay the sidebar in portrait unless `.balanced`.

### The Apple TV journeys

`DionysusTVUITests` drives the app with `XCUIRemote`, against the same stub
and launch arguments (`TVUITestCase.launch`); selectors live under
`A11yID.TV`.

- **Focus moves only by remote presses** (`TVUITestCase.press`), so a journey
  reads as the presses a person would make.
- **Focus settles asynchronously**, after a press and after data arrives, so
  check it with `TVUITestCase.waitForFocus`, never a bare `hasFocus` read. A
  failed wait attaches the element tree to the result. `waitForFocus` checks
  once a second; poll when something must land sooner.
- **Rails are lazy**: only what's on screen is in the tree, so a journey
  presses down to a later rail rather than querying for it, and walks a row to
  reach its end (a See All).
- **The sidebar's state is read from its container's width** (under 100pt
  collapsed, over 300pt open) and polled (`waitForExpanded`/`waitForCollapsed`,
  `TVShellJourney.isCollapsed`): an `NSPredicate` on `frame` never matches, and
  on tvOS 27 the one row left reports the whole rail's frame.
- **Helpers**: `launchAtHome` waits for the hero's Play; `launchAtHomeTile`
  (or `focusFirstRailTile`) moves to Continue Watching's first tile;
  `openDetailFromFocusedTile` and `playFromFocusedTile` reach a detail page
  and the player.
- **The player's focus is read from a marker** (`A11yID.TV.Player.focus`),
  since the player draws focus from its own state, not the focus engine.
  Transport journeys pass `-UITestDisableControlAutoHide YES` unless checking
  the fade. The logo fallback is read from `A11yID.Media.heroLogoFallbackVisible`.
- **What XCUITest can't do on tvOS**: type reliably into a `SecureField`
  (journeys stop at the password field; sign-in is `LoginViewModelTests`'),
  drive the alphabet index (it needs a held scroll), read a hint or an
  announcement, run VoiceOver, or turn on an accessibility display setting.
  idb's arrow keys don't reach the system keyboard either. Those are checked
  by hand (below).

### Accessibility audits

`AccessibilityAuditTests` (one per app) runs `performAccessibilityAudit()`
over every screen the app can reach: about ten lines per screen, and the only
tests that can fail for a reason nobody thought to assert.

**They gate on structural issues only**: `.elementDetection`, `.hitRegion`,
`.sufficientElementDescription` and `.trait` (`.action` and `.parentChild` are
macOS-only). An unlabeled control, a label that isn't human-readable, a trait
contradicting the element: a bug on any reading. **Not gated**: `.contrast`,
`.dynamicType` and `.textClipped`, 145 of the 154 issues `.all` reported over
the twelve screens of 2026-09-06. They come from deliberate app-wide choices
(the secondary caption colour, fixed-size tiles whose one-line captions can't
grow without reflowing every grid), so turning them on would mean 145
suppressions, a rubber stamp. **If you widen `auditedTypes`, fix the findings
rather than suppressing them.**

Suppressions are scoped to a kind of element, not an audit type
(`isKnownAcceptable`): the system keyboard (any `.key`, and the QuickType
cell on the New Playlist form), UIKit's 20.5pt "Clear text" button in
`.searchable`, and the hit region of non-interactive `StaticText` metadata
lines. On tvOS the hit region of static text is suppressed throughout, since
nothing is pointed at. `auditCurrentScreen(underModal: true)` lets through one
exact shape (an `.elementDetection` "Potentially inaccessible text" issue
with no element) for audits taken under a modal that dims the screen behind
it; everything in the modal is still audited.

### Writing a journey

1. iOS journeys go in `DionysusPlayerUITests/Journeys/` with their selectors in
   a screen object in `Screens/`, so tests read as user intent; Apple TV
   journeys go in `DionysusTVUITests/` with helpers in `Support/`.
2. **Add a new identifier to `A11yID` in the same change that applies it.** A
   constant nothing uses looks like a selector and never resolves.
3. Launch through `UITestCase.launch(...)`/`TVUITestCase.launch(...)`, never a
   hand-built `XCUIApplication`: that's where the flake mitigations live.
4. New files need `xcodegen generate`. Add a journey to a smoke plan only if it
   belongs in the PR gate; keep those plans small.
5. **Check it fails.** Break the thing it covers and watch it go red.
   `testOpeningAnItemFromHome` once passed with `PosterCard`'s destination
   broken, because `.firstMatch` resolved to the hero's tile.

**An intermittent failure may be a crash, not flake.** The tell is an empty
`app.debugDescription` (`Query chain: Find: Target Application`) with
"Restarting after unexpected exit, crash, or test timeout" in the log. Look
for a `Dionysus-*.ips` in `~/Library/Logs/DiagnosticReports/` before touching
the test; its stack names the trapping accessor. That's how the suite found
bulk delete trapping in SwiftData (`DownloadsRow` held the live model).

**Keep both base classes' `setUp`/`tearDown` synchronous, and never make a
test method `async`.** In Xcode 26 a UI test with `continueAfterFailure =
false` and an async `setUp`, `tearDown` or test has its runner terminated at
its first failure, so the plan's `retryOnFailure` never runs (Apple's known
issue 108565878, [forum thread 809989](https://developer.apple.com/forums/thread/809989));
until 2026-10-09 every iOS UI failure in CI was final. A retried failure shows
as "Iteration 2 of 3" in the log.

## Where they run in CI

**iOS** goes through one reusable workflow, `.github/workflows/ui-tests.yml`,
which owns the matrix: an **iPhone 16** and an **iPad (A16)** on

| iOS | Why | PR smoke | Full plan (PRs into `stable`, nightly, release) |
| --- | --- | --- | --- |
| 26.5 | Latest runtime for the pinned Xcode (26.6) | ✓ | ✓ |
| 18.6 | The previous major and the deployment floor | | ✓ |

iOS 18 is the only place the pre-26 branch of an `#available(iOS 26, *)` check
runs. No image has both runtimes and Xcode won't download an iOS 18 one, so
26.5 runs on `macos-26` with Xcode 26.6 and 18.6 on `macos-15` with Xcode 26.3
(it tests the OS, not the toolchain). The models are the same on both
versions (the 16, since the 17 can't run iOS 18), so a failure on one OS isn't
a screen-size difference. Locally, Apple offers an iOS 18.2 runtime (`xcrun
simctl runtime add <dmg>`); iPad (A16) needs 18.3, so use iPad (10th
generation), the same 820×1180pt screen. Each environment runs with
`fail-fast: false` and uploads a failed `.xcresult` as
`ui-test-results-<plan>-<device>-iOS-<version>`.

**Apple TV** has its own reusable workflow, `.github/workflows/tv-ui-tests.yml`:
an Apple TV 4K (3rd generation) with Xcode 27.1 on GitHub's `xcode-27` image,
one job per tvOS version. `TVUITests-Smoke` runs on tvOS 27.0 on every PR;
`TVUITests` on 27.0 nightly and on PRs into `stable`. `release.yml` doesn't run
it while the Apple TV app isn't shipped. A failed job uploads
`tv-ui-test-results-<plan>-tvOS-<version>`.

- **Not tvOS 26.5, and not `macos-26`** (#319): on tvOS 26.x in CI the
  accessibility tree never shows a page the shell opens after launch. The
  recording shows the page, but every tree XCUITest reads still lists Home, so
  four of the seven smoke journeys fail. Not SwiftUI animation, remote query
  evaluation, the runner's simulator, the host (`macos-26` and `xcode-27`),
  Xcode (26.6 and 27.1) or a missing screen-changed notification; each was
  tried. tvOS 27.0 passes on the same runner and 26.5 passes on a Mac. So 26.5
  runs nightly only, as `tvOS floor smoke tests` with `allow-failure`
  (downloading its runtime, about five minutes). When it passes, make it a PR
  check.
- **The first test's warm-up**: on tvOS 27.0 in CI the first UI test sometimes
  read a tree seconds behind the app (PR #325), failing its retry too, while
  every later test and a job re-run passed. So before the plan the workflow
  runs one journey as a warm-up (`warm-up-test`), its result ignored. The
  same lag shows on a tvOS 26.5 Simulator locally; "Running the tests" has
  the local warm-up.

**Required checks.** `develop` requires the iOS build and unit tests, the
Release compile, GitGuardian, both `UI smoke tests / <device>, iOS 26.5`
checks, `tvOS build and unit tests` and `tvOS UI smoke tests / Apple TV 4K,
tvOS 27.0`. `stable` requires the same minus the tvOS UI smoke, plus the two
CodeQL "Analyze" checks and the four `Full UI tests / <device>, iOS <version>` checks, which is why a
PR into `stable` runs the full plan (`pr-checks.yml`'s `ui-full` job, named to
match). **Check names embed the device and OS**, so changing either renames
them, and both rulesets must be updated in the same change. A nightly
dispatched on a PR's branch reports checks of the right names, but GitHub
doesn't count them towards the PR (#290).

A release signs and uploads nothing until every environment has passed, and
nightly and release call the same workflow, so dispatching "Nightly UI tests"
on a branch (`gh workflow run nightly-ui-tests.yml --ref <branch>`) is a dry
run of a release's UI stage. When CI moves to a new Xcode, the Xcode version
(`setup-ios-project`), runner labels and `ui-tests.yml`'s version list change
together; from Xcode 27 the full matrix grows to three iOS versions (26
becomes the previous major, 18 stays as the floor).

Pipe `xcodebuild` through `xcbeautify` only with `pipefail` set: without it
the nightly reported success for weeks while the iPad audits failed (#258).

## Checked by hand

What no suite can reach, and how it was or should be checked.

**On a device**

- **Real playback**: decode, HDR, transcodes, seeking, the AetherEngine
  backward-seek wedge (the 8s seek watchdog turns it into a visible failure;
  watch for its log line in normal use) and Picture in Picture failures.
- **Mid-playback connectivity loss**: start playback and cut the server's
  network. `PlayerViewModelTests` pins the view-model side; the
  "Reconnecting…" label and the offline-versus-error overlay need a real
  dropped source, since AetherEngine's own HTTP reader is involved.
- **The player's error overlays** (Close only for a refused source, Retry for
  rate-limited or transient): pinned at the view-model level; the rendering
  was checked on device with a nonexistent item id.
- **Downloads in the background**: a real background transfer landing bytes,
  surviving backgrounding and resuming after a relaunch. `MockURLProtocol`
  can't intercept delegate-based download tasks and the Simulator's background
  sessions differ from a device's. Check: download an item, play it in
  Airplane Mode (HEVC, audio track, subtitles; HDR sources play tone-mapped to
  SDR, a Jellyfin limitation), background the app mid-download (don't
  force-quit), and confirm reconnecting syncs watched and resume state.
  To capture device evidence for a background-transfer bug:

  ```sh
  sudo /usr/bin/log collect --device-udid <UDID> --last 15m --output before.logarchive
  /usr/bin/log show before.logarchive --info --debug --style compact \
    --predicate 'process == "nsurlsessiond" OR subsystem == "com.apple.CFNetwork"' \
    | grep -E 'dionysus|-997|-996|BackgroundSession'
  ```

  `<UDID>` is the hardware UDID: `xcrun devicectl device info details
  --device <identifier> | grep udid`.

**In the Simulator, by hand**

- **iOS**: swiping a search-history row away (a synthesized swipe on its
  `Button` can register as a tap), and re-tapping the Search tab on iPad (the
  floating tab bar leaves the tree once the field has been engaged; tapping
  away from the field is the real way out, and no synthetic tap triggered it).
- **The Apple TV alphabet index** (`TVAlphabetIndexTests` pins its letters and
  jump targets), the 30-minute return to Who's Watching? (`AppStateTests` pins
  the rule with injected dates), and the space bar as Play/Pause (`idb ui key
  <udid> 44`).
- **Display settings on the Apple TV** (Reduce Transparency, Reduce Motion,
  Increase Contrast, Bold Text): XCUITest can turn none on, so they were
  checked by screenshot on the tvOS 26.5 Simulator, each alone. Turn one on
  with `xcrun simctl spawn <udid> defaults write com.apple.Accessibility <key>
  -bool true`, then `notifyutil -p com.apple.accessibility.cache.<name>` and a
  relaunch. Keys: `ReduceMotionEnabled`, `EnhancedBackgroundContrastEnabled`
  (Reduce Transparency), `DarkenSystemColors` (Increase Contrast),
  `EnhancedTextLegibilityEnabled` (Bold Text). Pages checked: Home, a detail
  page, Profile, the grid's pills and lists, the sidebar and the player.
- **VoiceOver on the Apple TV**: announcements, hints (each settings footer is
  its row's hint), the open sidebar's modal trait, titles read beside Play,
  container names spoken on the way in, the collapsed rail's dimmed rows
  staying unread, the hero's Next Item and Forget This Account actions
  (reached by a swipe the Simulator's keyboard can't send, so not yet heard),
  and the accessible transport's scrubber steps. The journeys pin what
  XCUITest can see (containers, labels, values, identifiers); the unit tests
  pin the rules (`TVSidebarLayoutTests`, `TVSearchGroupingTests`,
  `TVOnboardingSpeechTests`, `TVHeroPagerTests`, `TVAccessibleTransportTests`).
  To hear VoiceOver in the Simulator, read its log: `xcrun simctl spawn
  <udid> log stream --level debug --style compact --predicate 'category ==
  "VOTSpeech"'` prints each "Post-processed string", one key press at a time. If nothing is
  spoken although the setting is on, `launchctl start
  com.apple.VoiceOverTouch` in the Simulator starts it.

## Where each thing is tested

One line per test file: what it pins. The test names and doc comments carry
the detail.

### iOS and shared unit tests (`DionysusPlayerTests/`)

| File | Pins |
| --- | --- |
| `App/AppStateTests` | The phase machine, sign-in and silent sign-in, sign-out, offline launch, and tvOS's Who's Watching? launches |
| `Core/Downloads/DownloadFileStoreTests` | Download file paths, sidecars and cleanup |
| `Core/Downloads/DownloadManagerTests` | Delete (cancelling the task), the queue, one background session, retry budget and error classification |
| `Core/Downloads/DownloadStoreTests` | SwiftData round-trips for downloads |
| `Core/Downloads/DownloadSyncManagerTests` | Pushing offline watched and resume state on reconnect |
| `Core/Downloads/DownloadTypesTests` | The quality ladder's bits-per-pixel rule (`DOWNLOADS.md`) |
| `Core/Downloads/DownloadedItemTests` | A download's estimated size |
| `Core/Downloads/FileSizeTextTests` | File sizes shown and spoken |
| `Core/Downloads/OfflineTrickplayThumbnailProviderTests` | Scrub thumbnails from downloaded trickplay sheets |
| `Core/Models/LicenseDocumentTests` | The License page's text: the app's licence, then each bundled library's notices under its name; every library that ships has them |
| `Core/Models/MediaCollectionRailTests` | A rail's tile shape, decided for the whole rail |
| `Core/Models/MediaItemTests` | All display logic: dates, durations, labels, badges, versions, image URLs and fallbacks, optimistic updates, equality |
| `Core/Models/SearchResultTests` | Search hints mapped for display |
| `Core/Models/ServerConfigurationTests` | Parsing a typed server address |
| `Core/Models/WatchBadgesTests` | Which corner badges a tile shows, on both platforms |
| `Core/Networking/ConnectivityMonitorTests` | Offline detection |
| `Core/Networking/DeviceProfileTests` | The `DeviceProfile` sent for transcoding decisions |
| `Core/Networking/ImageURLBuilderTests` | Image and trickplay URLs |
| `Core/Networking/JellyfinAPIClientTests` | Request building, decoding, re-authentication, timeouts, Quick Connect, playlists, deletion, subtitles and attachments |
| `Core/Networking/JellyfinAPIErrorTests` | Error messages |
| `Core/Networking/JellyfinAuthorizationTests` | The `Authorization: MediaBrowser` header |
| `Core/Networking/JellyfinCodingTests` | Jellyfin's JSON coding |
| `Core/Networking/LibraryAvailabilityTests` | Library availability and its retry |
| `Core/Networking/RemoteImageLoaderTests` | Retry with backoff, caching, de-duplication |
| `Core/Networking/ServerDiscoveryTests` | Parsing discovery replies; the subnet sweep |
| `Core/Networking/TrickplayThumbnailProviderTests` | Trickplay tile maths and fetching |
| `Core/Persistence/DeviceIdentityTests` | The device id, made once and kept; client and device names |
| `Core/Persistence/DownloadPreferencesStoreTests` | Download preferences |
| `Core/Persistence/DownloadQualityLadderStoreTests` | Per-device ladder overrides |
| `Core/Persistence/KeychainStoreTests` | Keychain round-trips and scopes |
| `Core/Persistence/MediaVersionPreferenceStoreTests` | The remembered media version |
| `Core/Persistence/SearchHistoryStoreTests` | Search history and its cap |
| `Core/Persistence/ServerSessionStoreTests` | Server and credentials storage; tvOS's remembered accounts and `moveSession` merges |
| `Core/Persistence/StreamPreferenceStoreTests` | Streaming mode and bitrate defaults |
| `Core/Persistence/TrackPreferenceStoreTests` | Remembered audio and subtitle choices |
| `Core/Playback/ASSSeekHoldTests` | Holding libass back until the engine re-measures after a seek |
| `Core/Playback/ASSSubtitleGeometryTests` | libass's frame, margins and font scale in both orientations |
| `Core/Playback/AetherPlaybackEngineClassificationTests` | Playback errors classified as refused, rate-limited or transient |
| `Core/Playback/AetherPlaybackEngineLoadOptionsTests` | The display context passed to the engine |
| `Core/Playback/StreamFormatDescriptionTests` | Stream format labels for Playback Stats |
| `Features/AssetDetails/AddToPlaylistViewModelTests` | The Add to Playlist picker: editable destinations, adds, creating one |
| `Features/AssetDetails/AssetDetailViewModelTests` | Detail pages by kind: loading, play targets, seasons, watched and favourite, deletion, playlists |
| `Features/Collection/CollectionGridViewModelTests` | Grid queries, sorting and the cascading filters |
| `Features/Downloads/DownloadsRowCaptionTests` | A download row's caption |
| `Features/Downloads/DownloadsViewModelTests` | Grouping and bulk actions on the Downloads tab |
| `Features/Home/DynamicRailCandidateTests` | Which dynamic rails Home offers |
| `Features/Home/HomeViewModelTests` | Home's fan-out, the hero, retries after reconnecting |
| `Features/Login/LoginViewModelTests` | Sign-in and its errors |
| `Features/Login/QuickConnectViewModelTests` | Quick Connect polling, expiry and sign-in |
| `Features/Login/UserAvatarTests` | The sign-in avatar's image URL |
| `Features/Player/ASSSubtitleMappingTests` | Which tracks go to libass, the ordinal mapping, the styling setting and the font source |
| `Features/Player/PlaybackRequestTests` | A playback request's identity (start from the beginning, media version) |
| `Features/Player/PlaybackStatsReportTests` | Playback Stats' rows |
| `Features/Player/PlayerControlsOverlayTests` | The skip step |
| `Features/Player/PlayerViewModelOfflineTests` | Offline playback of downloads |
| `Features/Player/PlayerViewModelTests` | Resume, reporting, transport, tracks, versions, errors, the background reload and stopping while offline |
| `Features/Player/SubtitleOverlayLayoutTests` | Subtitle metrics on phone and TV |
| `Features/Profile/QuickConnectApprovalViewModelTests` | Approving another device's code |
| `Features/Search/SearchViewModelTests` | Search and its history |
| `Features/ServerSetup/ServerSetupViewModelTests` | Connecting, the HTTP fallback, the Local Network prompt, discovery |
| `Shared/AppVersionInfoTests` | The version string |
| `Shared/BackdropLogoOverlayTests` | The hero logo's tilt rotation |
| `Shared/Components/AsyncRemoteImageFillTests` | Placeholders while loading and after failure |
| `Shared/Components/HeroScrollEdgeScrimTests` | The hero's scroll-edge scrim and status bar |
| `Shared/Components/OnboardingLayoutTests` | Onboarding's composition per measured device size |
| `Shared/Components/ToastCenterTests` | Toasts |
| `Shared/DeviceTiltObserverTests` | Tilt smoothing and the sensor's reference counting |

### Apple TV unit tests (`DionysusTVTests/`)

| File | Pins |
| --- | --- |
| `MediaPlaceholderGlyphTests` | The placeholder glyph's scale on TV |
| `SessionScopeSettingTests` | Follow Apple TV Users and Select a User Every Relaunch: defaults, storage, when Who's Watching? is asked |
| `TVAccessibleTransportTests` | When the accessible transport is on, and what it announces |
| `TVAlphabetIndexTests` | The grid's alphabet index: letters, jump targets, direction |
| `TVAppIconTests` | The icon and Top Shelf images are in the bundle |
| `TVAppLaunchTests` | What the app's own launch sets up |
| `TVChapterProgressTests` | The Chapters tab's progress bars |
| `TVDetailFormatTests` | Detail-page text (time left, Play's title) |
| `TVDetailHeaderArtTests` | The image beside a title with no backdrop |
| `TVEpisodeLogoTests` | Which tiles carry a show's logo |
| `TVHeroPagerTests` | When the hero's timer runs, and paging |
| `TVHeroPlayTargetTests` | What Play on a series plays |
| `TVKeyboardCommandTests` | The space bar as Play/Pause |
| `TVMotionTests` | Reduce Motion dropping a moving animation; Increase Contrast drawing translucent text solid |
| `TVOnboardingSpeechTests` | The Quick Connect code spoken; discovery announcements |
| `TVPageKeepAliveTests` | Which pushed pages stay built |
| `TVPlaybackSessionTests` | A session's start, end and reported outcome |
| `TVPlaybackTimeFormatTests` | Player times |
| `TVPlayerAccessibleTransportTests` | The reducer in the accessible mode |
| `TVPlayerCommandRunnerTests` | Commands reaching the engine through the view model |
| `TVPlayerContextTests` | What the player accepts input in |
| `TVPlayerFlashTests` | The play, pause and skip glyphs; the scrubber's knob |
| `TVPlayerFocusIDTests` | The player's focus marker |
| `TVPlayerHostAdvanceTests` | What resets for the next item |
| `TVPlayerInfoArtTests` | The Info tab's art |
| `TVPlayerInputModelTests` | The remote as a table: state, input, commands |
| `TVPlayerInputTests` | The input model's driver: fades, resets, announcements |
| `TVPlayerOverlaysTests` | Skip and Next Up as focus stops |
| `TVPlayerPanelTests` | The swipe-down panel |
| `TVPlayerPresenterTests` | No second player in the presented chain |
| `TVPlayerScrubTests` | Scrubbing and scanning |
| `TVPlayerSurfacePolicyTests` | Which view draws each route |
| `TVPosterCellTests` | A grid poster's inset while loading or without art |
| `TVPosterCollectionViewTests` | When focus enters the grid, so posters settle |
| `TVProfileIdentityTests` | The sidebar's Profile entry, offline too |
| `TVScrubThumbnailLoaderTests` | Throttled, ordered scrub thumbnails |
| `TVSearchGroupingTests` | Search's rails and its announcements |
| `TVSeasonEpisodesModelTests` | A show's episodes a season at a time |
| `TVSettingsRowTests` | A destructive row's look at rest and in focus |
| `TVShellNavigationTests` | Where the shell is and which rows take focus |
| `TVShowArtTests` | Whose imagery a show's page draws |
| `TVSidebarLayoutTests` | The sidebar's rows, the fold, icons, hidden rows |
| `TVSidebarModelTests` | The sidebar's library load |
| `TVSignInRouteTests` | Where choosing a user leads |
| `TVSignOutTests` | Sign Out forgets; Switch User keeps |
| `TVSwipeGateTests` | Swipes becoming scrubs or steps |
| `TVTextPageViewTests` | The License page: each library's notices after its name, as a heading |
| `TVTileCaptionTests` | A caption's lift under a focused card |
| `TVTileShapeTests` | Posters or landscape, per rail or grid |
| `TVTransportLayoutTests` | The scrubber, buffered bar and preview |
| `TVWhosWatchingLayoutTests` | Who's Watching? order |

### iOS journeys (`DionysusPlayerUITests/Journeys/`)

| File | Covers |
| --- | --- |
| `AccessibilityAuditTests` | The structural audit over every screen |
| `AddToPlaylistJourneyTests` | Adding to a playlist: the editable filter, confirmations, creating one |
| `AssetDetailJourneyTests` | The detail layouts (favourite and watched, resume, episodes, box sets, playlists), deletion and its permission gate, deleting a season (folderless too), removing a playlist item |
| `AuthJourneyTests` | Welcome, server setup, discovery, the HTTP fallback, every sign-in path |
| `CollectionJourneyTests` | Grid filters (combined, never emptying the grid), Random |
| `DownloadsJourneyTests` | Downloading to completion, the row updating while open, bulk delete, cancelling a selection |
| `HarnessTests` | The harness itself: scenarios served, state cleared between launches |
| `HeroLogoFallbackUITests` | The logo's text fallback timing |
| `HomeJourneyTests` | The hero, See All, and a refresh scrolling rails back to their start |
| `OfflineErrorJourneyTests` | `serverError`, `unauthorized` and `offline` |
| `PlayerJourneyTests` | Skips, the track and chapter pickers, Playback Stats' pages, the end of an item |
| `ProfileJourneyTests` | Quick Connect approval, Sign Out, Change Server |
| `SearchJourneyTests` | No results, a long history keeping the field visible, history across a relaunch |
| `SmokeJourneyTests` | The PR gate's journeys |
| `StyledSubtitleJourneyTests` | Styled subtitles, the styling setting, fonts not gating the script |

### Apple TV journeys (`DionysusTVUITests/`)

| File | Covers |
| --- | --- |
| `AccessibilityAuditTests` | The structural audit over every Apple TV screen |
| `AccountSwitchingJourneyTests` | Remembered accounts, Forget This Account, Follow Apple TV Users, Select a User Every Relaunch |
| `CollectionDetailJourneyTests` | Box sets and playlists, empty and loading |
| `CollectionGridJourneyTests` | A library's grid: pills, sort, filters, Reset, returning from a detail page |
| `DetailJourneyTests` | Detail pages: Menu, the keep-alive cap, rows, Full Details, no backdrop, failures |
| `HomeJourneyTests` | The hero, See All, rails loading, a failing Home |
| `LaunchJourneyTests` | First launch to Welcome and Find Your Server |
| `LoadingJourneyTests` | Home and a library loading slowly keep focus off the sidebar |
| `MenuToLandingJourneyTests` | Menu back to a page's landing view |
| `OnboardingJourneyTests` | Find Your Server, Who's Watching?, Quick Connect, the password screen |
| `PlayerAccessibleTransportJourneyTests` | The accessible transport, forced on |
| `PlayerJourneyTests` | The player opens, takes the remote and closes, loading too |
| `PlayerPanelJourneyTests` | The swipe-down panel's tabs and choices |
| `PlayerReturnJourneyTests` | Leaving the player back to the page as it was |
| `PlayerScrubJourneyTests` | Icons, scrubbing, scanning, glyphs |
| `PlayerSegmentJourneyTests` | Skip Intro and Next Up |
| `PlayerStatsJourneyTests` | The stats toggle and panel |
| `ProfileJourneyTests` | Profile's rows, pickers, covers and Sign Out |
| `SearchJourneyTests` | Search, Recent Searches, the full-screen layout |
| `ShowDetailJourneyTests` | A show's page: Play, season tabs, episodes, badges |
| `SidebarJourneyTests` | The sidebar: open, close, choose, fold, retry |
| `TileShapeJourneyTests` | Tile shapes on screen |
