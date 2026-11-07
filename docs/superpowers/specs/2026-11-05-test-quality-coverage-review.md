# Test quality and coverage review (2026-11-05)

A health check of the unit and UI tests for both apps, on every device type.
No incident prompted it. It ranks where the tests are weaker than they look;
Benjamin picks which to fix, and each fix gets its own plan and PR. Plan:
`docs/superpowers/plans/2026-11-05-test-quality-coverage-review.md`.

## 1. Summary

**The tests are good, and they reach most of the apps.** Some run reaches
84% of the apps' lines (the unit tests alone 77% of the logic; unit and UI
runs together 84% of the views), every area of the Apple TV app is at 82% or
more, a random sample of 30 tests had no weak one, and every device and Duo
pose reaches the code meant for it. The gaps are a few screens nobody opens,
paths that need a state the harness can't make yet, and two CI signals
nobody reads.

**The first ten, in rank order** (risk, then cost):

1. **TQ-01** Nothing taps Retry on an error state (High, S).
2. **TQ-02** #311's Apple TV focus fix has no test (High, S).
3. **TQ-03** The hero's auto-advance is never run (High, S).
4. **TQ-04** The tvOS 26 floor's smoke has failed most nights for three weeks, unread (High, M).
5. **TQ-05** No journey opens a downloaded item or plays one offline (High, M).
6. **TQ-06** Four Duo fold layouts run in every pose but are never checked against the fold (High, M).
7. **TQ-07** iOS's Next Up card is never drawn (High, M).
8. **TQ-08** `DownloadManager`'s background and relaunch paths are reached by no run (High, M).
9. **TQ-09** Server discovery is two-thirds unreached (High, M).
10. **TQ-10** The Apple TV's sign-in and server-setup error branches are unreached (High, M).

Four more High findings (TQ-11 to TQ-14) come next; three of them need a
new harness capability (L). **Two cheap Medium ones are time-sensitive:**
TQ-15 (11 Apple TV journeys that will fail the day CI moves to 27.2) and
TQ-16 (a Profile journey in smoke).

All 27 findings are in section 10.

## 2. How it was measured

**Finding format:** `TQ-NN` · title · area · devices · evidence (file:line,
numbers, run ids) · risk · cost · suggested fix.

**Risk.** **High**: a regression here would reach users with no test failing,
*and* the code is on playback, sign-in/session, downloads or navigation, or
changed in the last 60 days (since 2026-09-06). **Medium**: either one of
those. **Low**: neither, or the risk is cosmetic.

**Cost.** **S**: under half a day, tests in one file, no harness change.
**M**: a new journey, or tests across several files. **L**: needs a new
harness capability (a stub-server scenario, a fake-engine behaviour, a launch
argument) or CI changes.

Coverage numbers say a line was **reached** by a test run, never that it was
tested: a line can run under a test that checks nothing about it.

**The runs.** Every plan was run with code coverage on this Mac, on
`develop` at `4a8f3c4` (after #428), one at a time, on 2026-11-05:

| Run | Plan | Destination | Tests | Skipped | Failed | Minutes |
| --- | --- | --- | --: | --: | --: | --: |
| iOS unit | `UnitTests` | iPhone 17, iOS 27.2 | 1,477 | 0 | 0 | 2 |
| tvOS unit | `TVUnitTests` | Apple TV 4K (4th gen), tvOS 27.2 | 1,524 | 0 | 0 | 2 |
| iPhone | `UITests-Full` | iPhone 17, iOS 27.2 | 146 | 3 | 0 | 37 |
| iPad | `UITests-Full` | iPad (A16), iOS 27.2 | 146 | 5 | 2 | 40 |
| Duo closed / open / book / tabletop | `UITests-Full` | iPhone Duo, iOS 27.2, pose set by `Scripts/duo-pose/` | 146 each | 5–6 | 0 | 36–37 each |
| Apple TV | `TVUITests` | Apple TV 4K (4th gen), tvOS 27.2 | 244 | 0 | 11 | 72 |

(The tvOS unit count includes the shared iOS test files the tvOS target
compiles; the test-quality scan in section 7 counts each test once.)

**What differs from CI.** CI builds with Xcode 27.1 and runs iOS 27.0, the
Duo on 27.1, iOS 18.6 and tvOS 27.0 (3rd gen); this Mac has only Xcode 27.2
and the 27.2 runtimes. So the numbers here are 27.2's, and the iOS 18.6
floor wasn't run (section 5). The 13 failures are local to 27.2: none failed in CI's
nightlies since 2026-10-14 (one, `test_detail_overALibrary_returnsToItsTile`,
failed once on 10-13, likely for another reason; section 5 explains the
tvOS ones).
Failed tests still count toward coverage up to the point they failed. The harness excluded below is 7 files, 1,746 executable lines.

The Duo runs passed their pose to the test runner as a build setting rather
than an environment variable, so `duoPose` read nil and the two tests that
run only in book pose skipped. Those two were rerun in book pose with the
variable set (both passed) and that run is counted with book.

**How the numbers were made.** Line coverage comes from each run's
`xccov view --archive` (one entry per source line), combined by line across
runs. xccov's own report sums each function's lines, so lines inside nested
closures (most SwiftUI code) count more than once there; the per-line archive
doesn't. The combined counts were checked against xccov's report in every
file where the two agree on the number of executable lines (39 per iOS run,
54 for tvOS): all match but one line in `AsyncRemoteImage.swift`.

**Excluded:** the UI-test harness compiled into the app
(`Core/UITestSupport/`, `PreviewPlaybackEngine.swift`). Every file is tagged
**logic** (types with no view conformance), **view** or **mixed** (both in one
file, such as a view and its `@Observable` model).

## 3. Coverage by target and area

**Some test reaches 84% of the apps' 31,885 executable lines** (excluding
the harness). By kind:

| Kind | Lines | Unit tests | iOS UI (6 runs) | tvOS UI | Any run |
| --- | --: | --: | --: | --: | --: |
| Logic | 11,869 | 77% | 54% | 53% | 86% |
| Mixed | 3,306 | 11% | 58% | 21% | 79% |
| View | 16,710 | 4% | 50% | 37% | 84% |
| **All** | 31,885 | 32% | 52% | 41% | 84% |

The split works as designed: unit tests carry the logic, and the journeys
carry the views (and reach the view models again on the way). Per area, the
lowest:

| Area | Kind | Lines | Unit | iOS UI | tvOS UI | Any |
| --- | --- | --: | --: | --: | --: | --: |
| Core/Playback | logic | 1,825 | 42% | 25% | 25% | 51% |
| Features/Downloads | view + mixed | 1,430 | 0% | 28% | n/a | 28% |
| Features/Profile | view + mixed | 1,260 | 0% | 64% | n/a | 64% |
| Core/Downloads | logic | 1,451 | 53% | 64% | n/a | 80% |
| Features/Player | view | 2,584 | 0% | 78% | 7% | 78% |
| DionysusTV/Onboarding | view | 805 | 7% | n/a | 82% | 82% |
| Features/AssetDetails | view | 2,835 | 0% | 82% | n/a | 82% |
| Features/Home | mixed | 885 | 2% | 82% | n/a | 82% |
| Shared (top level) | logic | 112 | 45% | 38% | 16% | 57% |
| Top Shelf extension (`ContentProvider`) | logic | 51 | 0% | n/a | 0% | 0% |

Everything else is at 88% or more: Core/Models 98%, Persistence 100%,
Networking 89%, the view models in every feature 91–100%, and the Apple TV's
pages 88–98% (Home, Detail, Browse, Shell, Profile, the player's views),
reached almost entirely by its journeys. The Apple TV's own logic (the
player's transport and panels, the shell, Top Shelf's builders) is 94–100%.
`Core/Playback` is low because most of it drives the real engine
(section 4).

## 4. Code no test reaches

5,042 executable lines are reached by no run. Ranked by unreached lines ×
commits since 2026-09-06 (the riskiest is code that changes and isn't run),
the top 15, each read by hand (16 to 25 follow the table):

| # | File | Unreached / lines | Commits | What isn't reached |
| --: | --- | --: | --: | --- |
| 1 | `Core/Playback/AetherPlaybackEngine.swift` | 806 / 1,084 | 24 | The adapter to the real engine. Device only by design: the harness swaps in the fake. |
| 2 | `Features/Player/PlayerControlsOverlay.swift` | 148 / 1,371 | 14 | Scrub thumbnails (`requestScrubThumbnail`, the preview), "Reconnecting…", the Picture in Picture button, the audio offset section's reset, episode subtitle rows. |
| 3 | `Features/Home/HeroRailView.swift` | 128 / 591 | 11 | The hero's auto-advance, its fade, and the VoiceOver announcement of each new page: the harness freezes the carousel (`freezesAmbientMotion`), so none of it runs. |
| 4 | `Features/Downloads/DownloadedShowView.swift` | 313 / 313 | 3 | The whole screen: no journey opens a downloaded item (section 6). |
| 5 | `Features/Player/PlayerView.swift` | 168 / 486 | 5 | The VoiceOver-only "show controls" button (123 lines, `PlayerView.swift:300`), which exists only while VoiceOver is on, and the single-tap and auto-hide paths around it. |
| 6 | `DionysusTV/Player/TVPlayerHostController.swift` | 48 / 334 | 15 | Attaching the real engine's `AVPlayer`, and the touch-surface pan. Device only. |
| 7 | `Core/Downloads/DownloadManager.swift` | 221 / 897 | 3 | Background-session events, adopting in-flight downloads after a relaunch, `retry`, logo and segment bookkeeping; also untested by the unit tests: trickplay tiles, chapter images, fonts and subtitles for offline use, the transcode progress poll. |
| 8 | `Features/Player/SubtitleOverlayView.swift` | 70 / 241 | 9 | Positioned cues (ASS placement and alignment), styled runs and image (PGS) cues: the fake engine sends plain text only. |
| 9 | `DionysusTV/Browse/TVMainView.swift` | 25 / 385 | 21 | Little: the library row's late enabling and `popToRoot`. Well reached. |
| 10 | `Features/Downloads/DownloadedAssetDetailView.swift` | 119 / 119 | 4 | The whole screen. |
| 11 | `DionysusTV/Onboarding/TVLoginView.swift` | 62 / 255 | 7 | A sign-in error, a remembered Quick Connect account, "Other user". |
| 12 | `DionysusTV/Onboarding/TVServerSetupView.swift` | 62 / 237 | 7 | Error and HTTP-fallback branches. |
| 13 | `Features/Player/PlayerViewModel.swift` | 21 / 957 | 19 | Nearly all reached. |
| 14 | `Features/Profile/ProfileView.swift` | 29 / 484 | 13 | Downloads settings and the License and Privacy rows' destinations. |
| 15 | `Features/Downloads/Components/DownloadedPlayResumeButtonRow.swift` | 125 / 125 | 3 | Play and Resume from a download: never drawn. |

16 to 25: `DownloadsView` (55 of 357, its list with items), `ShowDetailView`
(50 of 291), `DownloadedSeasonView` (all 143), `DownloadsQualityLadderView`
(all 136), `DownloadButton` (65 of 282, its failed and queued states),
`HomeView` (32 of 294), the Apple TV's `TVPosterCollection` (23 of 400),
`ServerDiscovery` (114 of 170), `NextUpOverlay` (75 of 98) and
`ServerSetupView` (70 of 343, the HTTP-fallback prompt and errors).

**17 files are reached by no test at all:** the downloaded pages and their
parts (`DownloadedShowView`, `DownloadedSeasonView`,
`DownloadedAssetDetailView`, `DownloadedDetailTabsView`,
`DownloadedInfoMetadataRow`, `DownloadedPlayResumeButtonRow`, 936 lines),
the Downloads settings pages (`DownloadsQualityLadderView`,
`DeviceStorageBarView`, `DeviceStorageBreakdown`,
`AdvancedDownloadOptionsView`, 343), **the detail page's Cast and Details
tabs** (`CastCrewGridView`, `TechnicalDetailsView`, 123: no journey
switches tabs), `ScrubThumbnailPreview`, `LicenseView`,
`PrivacyPolicyView`, `DisplayContext` (the HDR display check, device only)
and Top Shelf's `ContentProvider`.

**What the reading adds to section 6:**

- **iOS's Next Up card is never drawn** (`NextUpOverlay.swift`, 75 of 98
  lines): no iOS journey plays to the end of an episode. The Apple TV's card
  (`TVNextUpCard`, 83 of 84) has a journey.
- **Nothing runs under VoiceOver.** The player's VoiceOver-only control and
  the hero's page announcements are written for VoiceOver users only, and
  no test turns it on. XCUITest can't start VoiceOver, so a launch argument
  that makes the app behave as if it were on is the way in.
- **The hero's auto-advance** is frozen in every journey. Its unit-level
  arithmetic isn't extracted, so nothing checks it advances, pauses on
  interaction or snaps at the ends.
- **Subtitle placement and image subtitles** are reached by no test; the
  unit tests cover parsing and timing (`Core/Playback`'s subtitle tests),
  not the overlay that positions them.

The device-only code (the engine adapter, the real `AVPlayer` host, the HDR
display check: about 865 lines) is out of reach of the Simulator by design,
and isn't counted as a finding.

## 5. Devices, poses and floors

**Each iOS device reaches about the same code**: 69–72% of the iOS app's
lines per run, and every run reaches only a few dozen lines no other does,
which are what's meant to differ:

| Run | Lines only it reaches | What they are |
| --- | --: | --- |
| iPhone | 40 | The rotation lock and the player's rotate button (phone-sized screens only) |
| iPad | 39 | The tab bar's tint over the hero with a top tab bar (`TabBarTint`), iPad grid and rail widths |
| Duo closed | 0 | |
| Duo open | 4 | |
| Duo book | 25 | The grid's split around the fold (`PosterGridMetrics`, `FoldGapHStack`) |
| Duo tabletop | 22 | Sign-in split above and below the fold, Home's hero ending at the fold |

The iPad misses 53 lines every other run reaches, all of them phone-only
(the rotation lock, the welcome's phone layout). **Every fold layout is
reached in its pose**: `DetailBookSpread` 68 of 68 lines open and in book,
`ActiveFold` 60 of 60 across poses, `HeroFoldLayout` and
`OnboardingFoldSplit` in tabletop, `FoldGapHStack` in book. What's missing
is a check of where they put things (section 6).

**Skips per run** (all conditional and documented in the tests):

| Run | Skipped |
| --- | --- |
| iPhone | 3: the three Duo-fold tests |
| iPad | 5: those three, plus the two phone rotation tests |
| Duo closed | 6: the book-pose fold tests, rotation, the wide-hero test, sign-in off the fold |
| Duo open, book | 6: as closed, but sign-in runs; the slow detail-logo test skips (a known flake, section 9) |
| Duo tabletop | 5 |
| Apple TV | 0 |

`AuthJourneyTests:144` also skips when a hardware keyboard is connected; it
didn't here.

**The 13 failures on 27.2:**

- **The Apple TV's 11 are the tests, not the app.** Every one is a sidebar
  or Menu journey that waits for the rail to close (`isCollapsed`,
  `DionysusTVUITests/Support/TVShellJourney.swift:50`, "the sidebar's frame
  is narrower than 200pt"). On tvOS 27.2 the closed rail draws correctly,
  its icon strip beside the page with Home's Play focused (from the failed
  test's screen recording), but XCUITest reports the sidebar container's
  frame at its open width of 520pt. Two of them pass on the tvOS 27.0
  Simulator with the same build. (Whether the 4th-generation device or
  tvOS 27.2 is what changes it can't be told apart here: no Simulator has
  either on the other OS.) **They will fail the day CI moves to 27.2.**
- **The iPad's two** (`testHiddenUsersFallBackToTheSignInForm`: Home's rails
  didn't load in 15 s; `testQuickConnectApprovalHasNoAccessibilityIssues`:
  "Potentially inaccessible text") failed on both tries and have never failed
  in CI. Not investigated further; they need a look before CI moves to 27.2.

**iPad layouts are navigated, not asserted.** Profile's split view (on iPad
and the Duo held wide, `SettingsLayout.usesSplitLayout`) is driven by every
Profile journey through `Screens.swift`'s helpers, which go either way, but
no test checks that the iPad gets the split and the iPhone the list.

**Platform guards.** Shared code has 13 `#if DOWNLOADS` and 23 `#if os(...)`
blocks. Both sides of each are compiled and run by their own platform's
runs (iOS for the download paths, tvOS for the Apple TV's), so the
per-platform columns in section 3 already account for them; none showed up
among the hotspots.

**The floors aren't measured here.**

- **iOS 18.6** runs only in CI's nightly full plan. 26 `#available` checks in
  13 files take another path below iOS 26 or 27: 17 for iOS 26 (Liquid Glass,
  the toolbar and hero treatments; one also names tvOS 26), 7 for iOS 27.1
  (the fold) and 2 for iOS 27. Their older branches run on 18.6 only, so their coverage is unknown;
  the nightly is green there apart from known flakes.
- **tvOS 26** is the Apple TV app's floor; its smoke has failed most nights
  since 2026-10-13 (section 8).

**Top Shelf:** its logic (`DionysusTV/TopShelf`: the loader, builder,
artwork) is 97% reached by the tvOS unit tests, but the extension's entry
point (`DionysusTVTopShelf/ContentProvider.swift`, 51 lines) runs under no
test. The shelf's deep links have journeys (`TopShelfLinkJourneyTests`), but
nothing checks what the shelf itself shows. Two of its unit tests are weak
(section 7).

## 6. Journey and audit gaps

**The journeys reach nearly everything with an identifier.** Of the 329
identifiers in `A11yID`, the UI tests name all but 22 (a script compared
`AccessibilityIdentifiers.swift` with both UI-test targets; each claim below
was then confirmed by grepping for the identifier and the screen's helper).
The Apple TV journeys and audits are the most thorough: every page, the
player's panels and the sidebar have a journey and an audit. The gaps are on
iOS, in three places.

**Screens no journey opens (iOS):**

- **The downloaded pages**: `DownloadedAssetDetailView`,
  `DownloadedShowView` and `DownloadedSeasonView`. `DownloadsJourneyTests`
  downloads an item, watches its row and deletes it, but no journey opens a
  downloaded item, and **none plays one offline**: the one path a user takes
  with no server to fall back on. `PlayerViewModelOfflineTests` pins the view
  model; nothing drives the screens.
- **Downloads settings and the quality ladder** (`DownloadsSettingsView`,
  `DownloadsQualityLadderView`; identifiers `Profile.downloadsSettingsLink`,
  `qualityLadderLink`, `downloadsPane`): no journey and no audit. The ladder's
  numbers are unit-tested (`DownloadTypesTests`), its screen is not.
- **Advanced download options** (`AdvancedDownloadOptionsView`), **License**
  and **Privacy Policy**: no journey opens them.
- **The detail page's Cast and Details tabs** (`DetailTabsView`'s segmented
  picker; `CastCrewGridView`, `TechnicalDetailsView`): no journey switches
  to them, so both are 0% reached (section 4).
- **The end of an episode on iOS**: the Next Up card (`NextUpOverlay`) is
  never drawn; the Apple TV's has a journey. (Account details is opened
  on the way to Sign Out and Quick Connect approval, and Advanced Playback by
  the read-ahead and audio offset journeys.)

**Paths no journey takes:**

- **Retry from an error state** (`A11yID.State.retryButton`, in
  `StateViews.swift:59` and `:99`). `OfflineErrorJourneyTests` checks that the
  error and offline states appear, but nothing taps Retry and checks the screen
  recovers. Unit tests pin `reload()` on the view models; the button's wiring
  is unchecked.
- **Home's refresh button** (`Home.refreshButton`), **Picture in Picture**
  (`Player.pictureInPictureButton`, which can't run under the fake engine, so
  a tap-and-ask journey at most), **the unsupported-audio message** on a
  detail page (`AssetDetail.unsupportedAudioMessage`), and **cancelling the
  HTTP-port prompt** (`ServerSetup.httpPortCancelButton`).
- Apple TV: the More Actions playlist list's empty state and retry
  (`TV.Actions.emptyState`, `playlistsRetry`), and "Signing in to …"
  (`TV.Onboarding.signingInTo`).

**Accessibility audits.** iOS audits 28 screens and tvOS 38. iOS has no audit
of: the Downloads list with items in it (only its empty state), the
downloaded pages, box set and playlist pages, Account details, Downloads
settings, the quality ladder, License, Privacy Policy, and the player's track,
chapter and stats pages. **The Profile audit is
scoped wrong on the Duo:** `AccessibilityAuditTests.swift:305` scrolls with
`app.swipeUp()`, which starts at the window's centre. In book and tabletop
that is the fold, where the swipe scrolls nothing (`TESTING.md`, "On the
iPhone Duo Simulator", says no journey should do this), so the loop stops
with the list unmoved (at once if the last row is already drawn, else after
eight swipes) and the audit runs over the top of the list instead of the
end. Everywhere else it audits only the last screen
of Profile; the rows above are audited only where another test happens to
stop on them.

**The Duo's fold layouts in the UI tests.** Three journeys assert a layout
against the fold in the pose CI passes them (`duoFoldBand()`): sign-in
(`AuthJourneyTests.swift:233`), the grid's pills and posters
(`CollectionJourneyTests.swift:88`) and Home's offline and empty Downloads
states (`OfflineErrorJourneyTests.swift:47`). The other layouts run in every pose but
nothing checks where they put things. That covers **the player** in tabletop
(picture above the fold, controls below) and book (transport on the trailing
page), **the detail page's book spread** (whose poster is used only to decide
whether to skip a test), **Home's hero ending at the fold in tabletop**, and
**Search's centred states**. `TESTING.md` still lists these as checked by
screenshot because "XCUITest can't fold the device", but that stopped being
true when CI began setting the pose per job. Each could now get a
`duoFoldBand()` assertion like the three above. Their arithmetic is
unit-tested (`ActiveFoldTests`, `FoldGapHStackTests`, `PosterGridMetricsTests`
and the fold layouts' own tests), so what's missing is the check that the
views use it.

**"Checked by hand" items that could now be automated:**

- The Duo fold layouts (above).
- The tab bar's tint: still by hand. A journey can't read colour, and
  `TabBarTintTests` pins the rule.
- Swiping a search-history row away, the Apple TV display settings and
  VoiceOver speech: still out of XCUITest's reach, as `TESTING.md` says.
- Background downloads and real playback: device only.

Device reach (which runs reached each screen) is in section 5.

## 7. Test quality

**The tests are, on the whole, well written.** A script scanned all 2,272
tests (iOS unit 1,487, tvOS unit 395, iOS UI 146, tvOS UI 244; the iOS
unit count is test functions in the source, ten more than the 1,477 the
plan ran, which leaves out a few by device or plan) for weak
patterns, and every flag in playback, networking, downloads, the shared
view models and the player journeys was read by hand, plus a seeded random
sample of 30 tests from all four targets. **All 30 sampled tests compare a
real value or state**; none was weak.

| Flag (after hand reading) | Flagged | Confirmed weak | Notes |
| --- | --- | --- | --- |
| No assertion | 2 | 0 | Both are "must not crash" tests (`DownloadManagerTests:186`, `DownloadFileStoreTests:231`). `waitUntil` throws on timeout and the tvOS audits assert, so the tests that use them count as asserting. |
| Existence only | 10 | 2 | `TopShelfArtworkComposerTests:58` and `TopShelfArtworkTests:69` (TQ-22). The others are right for what they pin (an icon exists, an announcement is made). |
| Checks only a mock | 21 | 1 | Most assert on the request the client sent or on what was delegated to the engine, which *is* the subject's output. `PlayerViewModelTests:1314` is confirmed (TQ-17). |
| Fixed sleep | 75 sites | about 20 | Waits for something *not* to happen, stub-handler delays and polling loops are legitimate. Fixed waits in the tvOS journeys are not (TQ-24). |
| Skipped | 8 | 0 | All conditional `XCTSkip`s by device or pose, documented in the tests. Per-device skip counts are in section 5. |
| Near-duplicate (≥ 90%) | 163 pairs | 0 | Input-and-expected variants (table tests written one per case), mostly in `JellyfinAPIClientTests`, `MediaItemTests` and `DownloadTypesTests`. Not redundant; no finding. |

**Confirmed weak tests:**

- `PlayerViewModelTests.test_stop_whileOffline_skipsNetworkCallAndStillStopsEngine`
  (`DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift:1314`)
  asserts only `engine.stopCallCount == 1`. Its name promises that no network
  call is made, but nothing checks `MockURLProtocol.lastRequest`; a stop that
  sent its report while offline would pass. It also drives
  `ConnectivityMonitor.shared`, the shared singleton the flake work moved
  another test off.
- `TopShelfArtworkComposerTests.test_aLogoThatFails_drawsTheName`
  (`DionysusTVTests/TopShelfArtworkComposerTests.swift:58`) asserts only that
  artwork exists, so a composer that dropped the name fallback would pass.
  `TopShelfArtworkTests.test_render_withALogo` (`:69`) is the same: it checks the
  result is non-nil, not that the logo was drawn.
- **Fixed waits in the tvOS journeys**: about 20 sites, a minute or more of
  sleeping per run of the plan, among them
  `PlayerSegmentJourneyTests.swift:98` (12 s), `SidebarJourneyTests.swift:189`
  (8 s), `HomeJourneyTests.swift:160` (7 s), `PlayerJourneyTests.swift:87`
  (6 s), `CollectionDetailJourneyTests.swift:71` (4 s) and the
  `pastTheFade` waits in `PlayerAccessibleTransportJourneyTests`. Several wait
  out a timer (the transport's fade, Next Up's countdown) that a launch
  argument could shorten; the rest wait for focus or a load to settle, which
  a predicate wait would end sooner and more reliably. The 2026-11-03 flake
  review counted 17 of these as a flake source.

**The random-order plans** (`UnitTests-Random`, `TVUnitTests-Random`) match
their plans exactly today: the same targets, options and configurations,
apart from the order. Nothing checks that they stay in step (TQ-26).

## 8. The smoke plans

**What smoke runs.** `UITests-Smoke` (on `develop` PRs: iPhone and iPad on
iOS 27.0, and the Duo closed and open) runs seven tests: the harness's
keychain reset, first-run setup and sign-in, a seeded session opening on
Home, opening an item from Home and from a grid, searching for a known title,
and playing then closing an item. `TVUITests-Smoke` runs seven as well:
Welcome to Find Your Server, choosing a server then a user, Home's hero and
rails, a tile from Home and from a grid opening its detail page and Menu
returning, search, and the player's skip and Menu. Between them they cover
the "is the app usable at all" paths, which is what they're for.

**What reached `develop` and was caught only at night.** Every failed
`develop` nightly since 2026-10-12 (13 of 28 runs, counting 2026-11-06's) was read, failing test by
failing test:

- **Profile and its settings pages broke on some devices for days at a
  time**, and smoke runs no Profile journey. `ProfileHasNoAccessibilityIssues`,
  the Spatial Audio journeys and audits, `testAudioOffsetStepperAndReset` and
  `testReadAheadBufferStepsThirtySeconds` failed on the iPad (27.0 and 18.6)
  and the iPhone on 18.6 from 2026-10-20 to 10-22, until #374 (which changed
  `ProfileView` and the journeys); then on the Duo from 10-30 to 11-01,
  until #396 (Profile's split held tall, an app fix) and #417 (the journeys'
  scrolling). The Add to
  Playlist journeys failed on the iPad on 10-22. One Profile journey in
  smoke would have caught the iPad 27.0 and Duo failures at PR time,
  whether the app or the journey was at fault.
- **Every other night-only failure was a known flake**
  (`testEmptyLibraryScenarioIsServed`, the slow-logo tests), since fixed or
  listed in section 9.
- **The tvOS 26.5 floor's smoke has failed on most nights since 2026-10-13**
  (search, the grid tile, the rail tile, the player's skip and Menu). It's an
  allowed failure, so nobody is made to look, and three weeks on, nobody
  knows whether the app or the tests are broken on tvOS 26. That's the
  Apple TV app's deployment floor, now in App Review. (TQ-04.)

**Fixes that landed without a test.** 62 PRs into `develop` since
2026-09-06 fixed something in app code. 51 of them changed tests too. Of the
11 that didn't, most are visual (the hero shade #390, toolbar symbols #388,
tab-bar tint #368, the episode title size #361, toolbar glass #230), or build
fixes (#353, #242). Three are behaviour with no test since:
**#310, keeping the Apple TV sidebar closed after sign-in on tvOS 26**,
which only the failing floor job could check; **#311, an Apple TV focus
claim stopping at the first press**; and **#225, the player wedging on a
spinner after a paused lock and unlock**, which needs a device. #254
(naming the server in the sign-out confirmation) is copy.

**What the full plans cost.** The iPhone's full plan takes 37 minutes here
(143 tests run, 3 skipped, 15 s each on average), the Apple TV's 72 (244 tests, 18 s).
The slowest are the Apple TV's More Actions delete journeys (44–56 s each)
and Profile's every-section walk (44 s), and on iOS the Add to Playlist
journeys and the audio offset and subtitle journeys (30–37 s each).

**Proposed changes** (costs in section 10):

1. Add one Profile journey to `UITests-Smoke` that opens Profile, a settings
   page and Spatial Audio. It's the one area that broke on `develop` for days
   at a time, and in device-specific ways that smoke's iPad and Duo legs
   would catch.
2. Make the tvOS 26.5 floor's smoke a real signal: find out whether it's the
   app or the tests, fix that, then make the job required (or drop it and
   say the floor is checked by hand).
3. Nothing in smoke is dead weight: every test in both plans exercises a
   path at least one later fix touched.

## 9. Flake follow-ups

The flake work (#421 to #428, done 2026-11-05) left a list of follow-ups.
The first `develop` nightly after it (run 42142259742, 2026-11-06, at
`4a8f3c4`) is one night, so a follow-up that didn't recur isn't proved fixed:

| Follow-up | 2026-11-06 nightly |
| --- | --- |
| tvOS: Select on a just-focused tile doesn't open its detail page (`openDetailFromFocusedTile`) | Not on tvOS 27.0. Still on the 26.5 floor (`TVShellJourney.swift:154`). |
| tvOS: `openMovies`' Down to Search missed | Not on 27.0. Still on the 26.5 floor (`TVShellJourney.swift:106`). |
| tvOS: `test_failedDetail` one-off | Didn't recur. |
| tvOS: VoiceOver's announcement after a post-playback pop | Owed on the Apple TV itself; not checked. |
| iPhone 17: Add to Playlist sheet one-off | Didn't recur. |
| Duo: `testEmptyLibraryScenarioIsServed` and the slow-logo retries | Every Duo pose passed first time. |
| tvOS 26.5 floor failures | Still failing: search, a grid tile, a rail tile, the player's skip (TQ-04). Closed 2026-11-07 as a limit of CI's machines: VoiceOver is unaffected and no CI setup tried passed (`TESTING.md`, "Not tvOS 26.5"). |

**What the night shows besides.** Every iOS job passed (iPhone and iPad on
27.0 and 18.6, the Duo in every pose), with one failure absorbed by a retry
(the iPhone's Search audit, a wait timing out). The Apple TV's full plan
failed, on one test in part 4:
`MoreActionsJourneyTests.test_deleteChosenEpisode_fromAnotherSeasonsTab_givesThePageBackToTheSeries`
"crashed with signal term" about two minutes in, under the plan's 300 s
allowance, with its screen recording left unfinished. It has no earlier
failure in the nightly history, and it's the plan's slowest test (56 s here).
Parts 1 to 3 passed only after retries absorbed **seven** failures: the
Spatial Audio About and no-results Search audits, the hidden audio offset,
a playlist's Play, an episode's wide art with no backdrop, and Search beside
the rail. None of these show in the weekly flake report, which counts only
failed jobs (a minor the flake work deferred): a night with eight flaky
failures reads as one red job (TQ-21).

## 10. All findings

Ranked by risk, then cost (cheapest first). Devices: **iOS** is every iOS
device; **Duo** the iPhone Duo; **TV** the Apple TV.

| ID | Finding | Area | Devices | Evidence | Risk | Cost | Suggested fix |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TQ-01 | Nothing taps Retry on an error state | Navigation, every page | iOS | `StateViews.swift:59`, `:99`; `A11yID.State.retryButton` named by no iOS test (section 6) | High | S | Extend `OfflineErrorJourneyTests` with the existing `librariesFailAtFirst` scenario (only the tvOS journeys use it today): fail, tap Retry, assert the content. |
| TQ-02 | #311 (an Apple TV focus claim stopping at the first press) has no test | Navigation | TV | Section 8 | High | S | A journey pressing twice where #311's claim was. |
| TQ-03 | The hero's auto-advance is never run | Home | iOS | `HeroRailView.swift` 128 of 591 lines unreached, 11 commits since 09-06; the harness freezes it | High | S | Pull the advance, pause and snap decisions into a type and unit-test it. |
| TQ-04 | The tvOS 26 floor's smoke has failed most nights since 2026-10-13, as an allowed failure | Navigation, playback | TV on tvOS 26.5 | Nightly history (sections 8, 9); #310 fixed sign-in there with no test | High | M | Find whether the app or the tests break on tvOS 26; fix; make the job required or drop it and say so. |
| TQ-05 | No journey opens a downloaded item or plays one offline | Downloads, playback | iOS | Six files, 936 lines, 0% reached (section 4); section 6 | High | M | A journey that downloads (as `DownloadsJourneyTests` does), goes offline, opens the show, season and item pages, and plays. |
| TQ-06 | The Duo's fold layouts run in every pose but four aren't checked against the fold | Playback, navigation | Duo | Player (tabletop, book), detail book spread, Home's hero in tabletop, Search's states; all reached (section 5), none asserted (section 6) | High | M | A `duoFoldBand()` assertion per layout in its pose, like sign-in's (`AuthJourneyTests.swift:233`). |
| TQ-07 | iOS's Next Up card is never drawn | Playback | iOS | `NextUpOverlay.swift` 75 of 98 lines unreached; the Apple TV's card has a journey | High | M | Port the Apple TV's Next Up journey, using the `earlyCredits` scenario. |
| TQ-08 | `DownloadManager`'s background-session events, relaunch adoption and trickplay tiles are reached by no run, and its offline extras by no unit test | Downloads | iOS | 221 of 897 lines unreached: `handleBackgroundSessionEvents`, `adoptInFlightDownloads`, `downloadTrickplayTiles`, most of `retry`. Subtitles, fonts and chapter images run only inside the UI download journey, which checks none of them | High | M | Unit tests over `MockURLProtocol` for each extra; a fake session for adoption and background events. |
| TQ-09 | Server discovery is two-thirds unreached | Sign-in | iOS, TV | `ServerDiscovery.swift` 114 of 170 lines unreached | High | M | Put the UDP socket behind a protocol and unit-test the sweep, replies and the denied-permission reading. |
| TQ-10 | The Apple TV's sign-in and server-setup error branches are unreached | Sign-in | TV | `TVLoginView.swift` 62 of 255 lines unreached (an error, a remembered Quick Connect account, "Other user"), 7 commits since 09-06; `TVServerSetupView.swift` 62 of 237 (error and HTTP-fallback branches) | High | M | Journeys over the existing `unauthorized` and `customHTTPPort` scenarios; the remembered Quick Connect account needs a way to seed a stored account, which the harness doesn't have. |
| TQ-11 | Downloads settings, the quality ladder, advanced download options, License and Privacy Policy have no journey or audit | Downloads, settings | iOS | 0% reached (section 4); section 6 | High | M | One journey through each, with an audit. |
| TQ-12 | Nothing runs under VoiceOver | Playback, Home | iOS | The player's VoiceOver-only control (`PlayerView.swift:300`, 123 lines) and the hero's page announcements are reached by no test | High | L | A launch argument that makes the app act as if VoiceOver were on, and a journey through the player's control. |
| TQ-13 | Positioned and image subtitles are drawn by no test | Playback | iOS | `SubtitleOverlayView.swift` 70 of 241 lines; the fake engine sends plain text cues only | High | L | Teach the fake engine to emit placed and bitmap cues, and assert their frames. |
| TQ-14 | Scrub thumbnails, "Reconnecting…" and the Picture in Picture button are unreached | Playback | iOS | `PlayerControlsOverlay.swift`, `ScrubThumbnailPreview.swift` 0% (section 4) | High | L | Fake-engine support for trickplay and a stall; a tap-only PiP check. |
| TQ-15 | 11 Apple TV sidebar journeys fail on tvOS 27.2 although the app is right | Navigation (tests) | TV on 27.2 | `TVShellJourney.swift:50` reads the sidebar's frame, which 27.2 reports at 520pt when closed (section 5) | Medium | S | Judge "closed" by a row's own frame or hittability, not the container's width. Needed before CI moves to 27.2. Graded outside the rubric: a test bug, no risk to users. |
| TQ-16 | Smoke has no Profile journey, and Profile broke on `develop` for days, twice | Settings | iOS | Nightly history (section 8) | Medium | S | Add one Profile journey (Profile, a settings page, Spatial Audio) to `UITests-Smoke`: about 30 s more per smoke job. |
| TQ-17 | `test_stop_whileOffline_skipsNetworkCallAndStillStopsEngine` can't fail on its network claim | Playback | iOS | `PlayerViewModelTests.swift:1314` (section 7) | Medium | S | Report playback start first, so the offline guard (`PlayerViewModel.swift:1680`) is what stops the request; then assert no stop request reached `MockURLProtocol`; give it its own connectivity monitor; fix its doc comment. |
| TQ-18 | The Profile audit doesn't scroll on the Duo's fold | Accessibility | Duo | `AccessibilityAuditTests.swift:305` uses `app.swipeUp()` (section 6) | Medium | S | Swipe from an element clear of the fold, as `TESTING.md` says. |
| TQ-19 | No journey opens the detail page's Cast or Details tab | Detail pages | iOS | `CastCrewGridView`, `TechnicalDetailsView` 0% (section 4) | Medium | S | Switch tabs in `AssetDetailJourneyTests`, and audit both. |
| TQ-20 | Two iPad journeys fail on iOS 27.2 and haven't been looked at | Sign-in, accessibility | iPad on 27.2 | `testHiddenUsersFallBackToTheSignInForm`, `testQuickConnectApprovalHasNoAccessibilityIssues` (section 5) | Medium | S | Triage before CI moves to 27.2. |
| TQ-21 | Retries hide the Apple TV's flakiness: seven failures absorbed in one night, invisible to the flake report | Tests | TV | Section 9; run 42142259742 | Medium | S | Count retried failures in `flake-report.yml` (the result bundle has every attempt), and look at the top few. |
| TQ-22 | Two Top Shelf tests check only that artwork exists | Top Shelf | TV | `TopShelfArtworkComposerTests.swift:58`, `TopShelfArtworkTests.swift:69` (section 7); both files changed since 09-06 | Medium | S | Compare pixels in the logo's and name's regions. |
| TQ-23 | iOS audits skip a dozen screens | Accessibility | iOS | Downloads with items, downloaded pages, box set and playlist pages, Account details, the player's track, chapter and stats pages (section 6) | Medium | M | Add audits; several ride on TQ-05 and TQ-11. |
| TQ-24 | About 20 fixed waits in the Apple TV journeys | Tests | TV | `PlayerSegmentJourneyTests.swift:98` (12 s) and others (section 7) | Medium | M | A launch argument to shorten the fade and countdown timers; predicate waits elsewhere. |
| TQ-25 | The Top Shelf extension's entry point runs under no test (its deep links do have journeys) | Top Shelf | TV | `DionysusTVTopShelf/ContentProvider.swift`, 51 lines, 2 commits since 09-06 (section 5) | Medium | M | A unit test of `ContentProvider` over a stub loader. |
| TQ-26 | Nothing keeps the random-order plans in step with their plans | Tests | iOS, TV | Section 7 | Low | S | A unit check (or CI step) that diffs the plan pairs apart from ordering. |
| TQ-27 | The iOS 18.6 floor's older branches aren't measured | Every area | iOS 18.6 | 26 `#available` sites in 13 files (section 5) | Low | M | Turn coverage on in the nightly 18.6 job and read those branches once. |

**Not findings:** the device-only code (the engine adapter, the real
`AVPlayer` host, the HDR display check, about 865 lines), #225 (device
only), and the near-duplicate tests (section 7).
