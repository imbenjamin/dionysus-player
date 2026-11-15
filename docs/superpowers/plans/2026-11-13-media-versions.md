# Media Versions (#289) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people choose which of a title's Jellyfin versions (quality renditions or editions) to view, play and download, on iPhone, iPad and Apple TV.

**Architecture:** One pure, shared decision type (`MediaVersionChoice`) says whether a start plays a known version or asks, from the item's versions, whether it resumes, and the remembered choice (`MediaVersionPreferenceStore`, which exists). Each platform draws the question its own way: iOS uses a `confirmationDialog`, the Apple TV a full-screen page like `TVAddToPlaylistPage`. A second pure type (`BulkVersionPlanner`) compares a season's scanned versions and decides between no question, one question for all, or one per episode.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (downloads), XCTest/XCUITest, the UI-test stub server (`UITestStubURLProtocol`, `UITestFixtureLibrary`).

**Spec:** Issue #289 (title only) and Benjamin's brief of 2026-11-13, restated under "Requirements" below. No separate spec doc.

## Requirements (Benjamin, 2026-11-13)

1. **Apple TV Details** mirror iOS's version tabs: a selectable Details panel per version, titled with `MediaItem.mediaVersions`' existing short label.
2. **Play from the start (no resume point)** asks which version to play.
3. **Resume** plays the previously chosen version without asking.
4. **iOS single download** (one movie or episode) asks which version to download.
5. **iOS bulk download** (a season) first scans every episode's versions. If they match, one question applies to all. If they differ, the user picks per episode.
6. Plan the unit tests and UI tests before implementing.

## What already exists (don't rebuild it)

- `MediaItem.mediaVersions` (`Core/Models/MediaItem.swift:397`) labels each source: an edition name, else "4K HDR10"-style, else the source name, else "Version N"; duplicate labels get " (2)" appended. Tests: `MediaItemTests` `test_mediaVersions_*`.
- iOS `PlayResumeButtonRow` already asks on **Play and Restart** when there are more than one version, and Resume uses `AssetDetailViewModel.preferredMediaSourceID(forPlayableItem:)`, the pick stored by `MediaVersionPreferenceStore` (per user, per item, `UserDefaults`).
- iOS `TechnicalDetailsView` already shows a segmented version picker.
- `PlayerViewModel.start()` already falls back to the server's default source when a requested `mediaSourceID` no longer exists (`PlayerViewModel.swift:664`).
- `DownloadedItem.mediaSourceID` is stored, and `DownloadManager.retry` keeps the source.
- Jellyfin `/PlaybackInfo` returns **every** source without `MediaSourceId` and **only that one** with it (`MediaInfoHelper.cs`, checked 2026-11-13).

## Decisions (confirmed by Benjamin, 2026-11-13)

| # | Question | Decision |
|---|---|---|
| D1 | Do row-level Play buttons ask too (iOS episode/collection/playlist rows; Apple TV Home hero, playlist members)? | **Yes** (agreed), same rule as the detail page. A row whose item lacks `MediaSources` fetches the item first. |
| D2 | Auto-advance (Next Up, a playlist queue): ask? | **Ask only when it can't carry the choice over.** Order: a single version plays (nothing to choose); else the remembered pick; else the version with the same label as the one just played; else **ask**. On iOS the question shows on the page after the player closes, as for any Play. On the Apple TV the player advances in place, so the question is shown over the player before the swap, and Menu on it closes the player. |
| D3 | `dionysus://` links and the Top Shelf: ask? | **Links never ask**: `source=` if given, else the remembered pick, else the server default. **The Top Shelf follows the page's rule** (resume plays the remembered pick, otherwise ask). Its links carry a new `from=topshelf` parameter, so the app can tell them apart from links typed or opened by tests. |
| D4 | Resume with no remembered pick (watched on another client, or the remembered source is gone): ask? | **Ask, and remember the answer.** |
| D5 | Restart: ask? | **Decided by the resume point, not the button** (Benjamin, 18:16): a title with a resume point never shows the picker, for Resume or Restart, and plays the remembered version. Without a remembered version it asks once (D4). Only titles with no resume point ask on Play. |
| D6 | A season where some episodes have only one version: does that count as "versions differ"? | **No** (agreed). Single-version episodes are left out of the comparison and download their only version. |
| D7 | Bulk download of a **collection**: no such button exists today (only `SeasonDownloadButton`). | **Out of scope**; raised as a new feature issue. The planner is generic, so a collection "Download All" could reuse it. |
| D8 | Mark the remembered version in the question? | **Yes**, "(Last Played)", like the download audio prompt's "(Previously selected)". |
| D9 | iOS long-press Advanced Download Options: where does version go? | **A Version picker in that sheet** (its size estimate depends on the source), so no separate question after it. |
| D10 | The Apple TV's summary Details panel (the page's 4-column grid) | Shows the **remembered or first** version, plus a "Versions" row ("4K HDR10, 1080p"). The full-screen details get the tabs. |
| D11 | Where the chosen version shows after the fact | A **"Version" row** in Playback Stats (both platforms) and on a downloaded title's Details. It's also what the journeys assert on. |

## Global Constraints

- iOS floor 18, tvOS floor 26.0; CI builds with Xcode 27.1 (`CLAUDE.md`).
- Shared code naming a Downloads type sits inside `#if DOWNLOADS`. A shared view model's change ships on both platforms.
- Never select on an accessibility label in UI tests. Never put an identifier on a screen-root container (`A11yID`).
- Strings: plain literals in SwiftUI views, `String(localized:)` elsewhere. Version labels from filenames and technical terms ("4K HDR10") stay unlocalized; "Original", "Version N", "(Last Played)" are localized. Sync `Localizable.xcstrings` with an Xcode.app build in the same change.
- Every toolbar button has a symbol and a title (`.toolbarTitleUnlessVertical()`).
- A decorative `Image(systemName:)` gets `.accessibilityHidden(true)` (accessibility audits).
- `BaseItemDto`/`MediaItem` equality stays structural.
- SwiftData: only add **optional** properties to `DownloadedItem` (lightweight migration).
- Apple TV questions are full-screen pages with Menu as cancel, never `.confirmationDialog` (`TVProfileView.swift:22`: its buttons lose focus styling).
- New journeys go in the full plans (`UITests-Full`, `TVUITests`), not the smoke plans.
- No commit or push until Benjamin has seen the diff (working preference).

## Review Focus

1. **The remembered source was deleted or replaced on the server.** Resume asks (D4) and the question doesn't mark a version that's gone: `MediaVersionChoice` only honours a preferred id found among the current versions. Test: `test_resume_preferredIDNoLongerPresent_asksWithNoMark` (Task 1).
2. **Cancelling the question** (iOS: dismissing the dialog or sheet; Apple TV: Menu) plays or downloads nothing, and leaves `DownloadButton`/`SeasonDownloadButton` idle rather than spinning. Tests: the `_cancel_`/Menu journeys in Tasks 4, 6, 7 and 8.
3. **A season where only some episodes have more than one version** (D6) gets one question when the multi-version ones match. Test: `test_plan_singleVersionEpisodesIgnored_uniform` (Task 8).
4. **Duplicate labels** ("1080p", "1080p (2)") map back to the right source on every episode in a uniform bulk choice: mapping goes by label, and labels come from the same function per episode. Test: `test_plan_uniform_mapsDuplicateLabelsPerEpisode` (Task 8).
5. **One episode's scan fails** (its `/PlaybackInfo` errors). The rest still plan and download, and that episode counts towards the "N episodes couldn't be downloaded" message. Test: `test_coordinator_scanFailure_countsAndContinues` (Task 8).

---

## File Structure

| File | Responsibility |
|---|---|
| `DionysusPlayer/Core/Models/MediaVersion.swift` (new; `MediaVersion` moves here from `MediaItem.swift`) | `MediaVersion`, `MediaVersion.versions(of:)` (labelling over raw sources) |
| `DionysusPlayer/Core/Models/MediaVersionChoice.swift` (new) | Pure start decision + continuation pick |
| `DionysusPlayer/Core/Downloads/BulkVersionPlanner.swift` (new, `#if DOWNLOADS` by folder) | Pure comparison of scanned seasons |
| `DionysusPlayer/Features/AssetDetails/Components/SeasonDownloadCoordinator.swift` (new) | `@Observable @MainActor` scan → plan → enqueue, injectable fetch |
| `DionysusPlayer/Features/AssetDetails/Components/VersionChoiceDialog.swift` (new) | iOS view modifier: the version `confirmationDialog`, reused by every iOS play entry point |
| `DionysusPlayer/Features/AssetDetails/Components/BulkVersionChoiceSheet.swift` (new) | iOS per-episode picker sheet |
| `DionysusTV/Browse/Detail/TVVersionPickerPage.swift` (new) | Apple TV full-screen version question |
| `DionysusTV/Browse/Detail/TVFullDetailsView.swift`, `TVDetailsPanel.swift` | Version tabs; "Versions" row |
| `DionysusPlayer/Features/AssetDetails/AssetDetailViewModel.swift` | `playbackDecision(for:isResume:)`, fetching sources when missing |
| `DionysusPlayer/Features/Player/PlayerViewModel.swift`, `PlaybackStatsReport.swift` | `activeVersionLabel`, "Version" row, continuation by label |
| `DionysusPlayer/Core/Downloads/DownloadedItem.swift`, `DownloadManager.swift` | `versionLabel: String?` stored at enqueue |
| `DionysusPlayer/Core/UITestSupport/*` | `.multipleVersions` scenario, fixtures, PlaybackInfo filtering |
| `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` | `A11yID.Versions.*`, the Apple TV tab ids, the Stats version value |

---

### Task 1: Shared version model and start decision

**Files:**
- Create: `DionysusPlayer/Core/Models/MediaVersion.swift`, `DionysusPlayer/Core/Models/MediaVersionChoice.swift`
- Modify: `DionysusPlayer/Core/Models/MediaItem.swift` (`mediaVersions` and its private label helpers move into `MediaVersion.versions(of:)`; `mediaVersions` delegates)
- Modify: `project.yml` only if the Top Shelf's `sources` list names `MediaItem.swift` individually (check, and add the new file beside it). Then `xcodegen generate`.
- Test: `DionysusPlayerTests/Core/Models/MediaVersionChoiceTests.swift` (new); the existing `MediaItemTests` `test_mediaVersions_*` must pass unchanged.

**Interfaces:**
- Produces:
  - `struct MediaVersion: Identifiable, Hashable { let id: String; let label: String }` (unchanged shape)
  - `extension MediaVersion { static func versions(of sources: [MediaSourceInfo]) -> [MediaVersion] }`: empty for fewer than 2 sources, otherwise exactly today's labelling
  - `enum MediaVersionChoice { case play(mediaSourceID: String?); case ask(versions: [MediaVersion], lastPlayedID: String?) }`
  - `static func MediaVersionChoice.decide(versions: [MediaVersion], isResume: Bool, preferredSourceID: String?) -> MediaVersionChoice`
  - `static func MediaVersionChoice.continuation(versions: [MediaVersion], preferredSourceID: String?, previousLabel: String?) -> MediaVersionChoice` (D2)

- [ ] **Step 1: Write the failing tests** in `MediaVersionChoiceTests`:

```swift
let versions = [MediaVersion(id: "4k", label: "4K HDR10"), MediaVersion(id: "hd", label: "1080p")]
func test_singleOrNoVersion_playsServerDefault() {
    XCTAssertEqual(MediaVersionChoice.decide(versions: [], isResume: false, preferredSourceID: "4k"), .play(mediaSourceID: nil))
}
func test_freshStart_asks_markingLastPlayed() {
    XCTAssertEqual(MediaVersionChoice.decide(versions: versions, isResume: false, preferredSourceID: "hd"), .ask(versions: versions, lastPlayedID: "hd"))
}
func test_freshStart_noPreference_asksWithNoMark() { /* lastPlayedID == nil */ }
func test_resume_playsPreferred() { /* .play(mediaSourceID: "hd") */ }
func test_resume_noPreference_asks() { /* D4: .ask(versions: versions, lastPlayedID: nil) */ }
func test_resume_preferredIDNoLongerPresent_asksWithNoMark() { /* preferred "gone" → .ask(lastPlayedID: nil) */ }
func test_freshStart_preferredIDNoLongerPresent_asksWithNoMark() { /* lastPlayedID == nil */ }
func test_continuation_singleVersion_playsWithoutAsking() { /* versions [] → .play(nil) */ }
func test_continuation_prefersRememberedThenSameLabel() {
    // versions [("n4k","4K HDR10"), ("nhd","1080p")]:
    // preferred "nhd" → .play("nhd"); preferred nil + previousLabel "1080p" → .play("nhd")
}
func test_continuation_noMatch_asks() {
    // previousLabel "Director's Cut" → .ask(lastPlayedID: nil); preferred "missing" + previousLabel nil → .ask(lastPlayedID: nil)
}
func test_versionsOfSources_matchesMediaItemMediaVersions() {
    // for each fixture in MediaItemTests' version tests: MediaVersion.versions(of: dto.mediaSources!) == item.mediaVersions
}
```

`MediaVersionChoice` gets `Equatable`.

- [ ] **Step 2: Run, expect a compile failure.** `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/MediaVersionChoiceTests -only-testing:DionysusPlayerTests/MediaItemTests`
- [ ] **Step 3: Implement.** Move the labelling (`canonicalSourceName`, `editionLabel`, `versionLabel` and their helpers) behind `MediaVersion.versions(of:)`; `MediaItem.mediaVersions` returns `MediaVersion.versions(of: dto.mediaSources ?? [])`. `continuation` matches the remembered id, then the label, else asks.
- [ ] **Step 4: Run the same command, expect PASS** (iOS), then `-scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' -only-testing:DionysusTVTests/MediaVersionChoiceTests`. The test file must be in `DionysusTVTests`' shared sources; check `project.yml`.

### Task 2: Stub server and fixtures for versions

**Files:**
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift` (new case), `UITestFixtureLibrary.swift`, `UITestStubURLProtocol.swift`
- Modify: `TESTING.md` (scenario table)
- Test: `DionysusPlayerTests/Core/UITestSupport/…` if a stub test file exists for PlaybackInfo (check); otherwise one test `test_playbackInfo_filtersByMediaSourceId` in a new `UITestStubPlaybackInfoTests.swift`

**Interfaces:**
- Produces: `UITestScenario.multipleVersions`. Fixture ids, in `UITestFixtureIdentity`:
  - `movie-1` (The Quiet Ascent, unwatched): sources `movie-1-4k` (3840×2160 HDR10) and `movie-1-1080p` (1920×1080 SDR), labelled "4K HDR10", "1080p"
  - `movie-2` (Signal Fire, part-watched): source names `Signal Fire` and `Signal Fire - Director's Cut`, ids `movie-2-original`, `movie-2-directors-cut`, labelled "Original", "Director's Cut"
  - Season 1 episodes: each with `<id>-4k` and `<id>-1080p` (uniform)
  - Season 2: `episode-s2e1` as above, `episode-s2e2` with editions "Original"/"Extended Edition", `episode-s2e3` single source (mixed)
  - Every other item: unchanged
- The stub's `/PlaybackInfo` returns every source of the item, or only the one named by `MediaSourceId` (as Jellyfin does). In every scenario: today's single-source fixtures are unaffected.

- [ ] **Step 1:** Write `test_playbackInfo_filtersByMediaSourceId` (under `.multipleVersions`: no id → 2 sources for `movie-1`; `MediaSourceId=movie-1-1080p` → 1 source with that id). Expect FAIL.
- [ ] **Step 2:** Implement: fixtures are built from `.standard`'s when `UITestHarness.scenario == .multipleVersions` (the same pattern `.folderlessSeasons` uses), and `playbackInfo(forPath:)` takes the request's query. Expect PASS.
- [ ] **Step 3:** Add the scenario to `TESTING.md`'s scenario list.

### Task 3: The player knows and reports its version

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift`, `PlaybackStatsReport.swift`; `PlaybackStatsOverlay.swift` and the Apple TV stats panel only if rows need an identifier hook
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift`
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift`, `PlaybackStatsReportTests.swift`

**Interfaces:**
- Consumes: `MediaVersion.versions(of:)`, `MediaVersionChoice.continuation` (Task 1)
- Produces: `PlayerViewModel.activeVersionLabel: String?`, which is `nil` unless the item's PlaybackInfo listed more than one source (read from the **unfiltered** list; see the step below). The Video section of `PlaybackStatsReport` gets a first row `Row("Version", label)` when non-nil, with the value identifier `A11yID.PlaybackStats.versionValue`. For auto-advance (D2): `PlaybackRequest.previousVersionLabel: String?` (iOS, where the page builds the next request) and `PlayerViewModel.nextItemVersionChoice: MediaVersionChoice?` (worked out when `nextEpisode` loads, fetching its sources if the item lacks them, from the remembered pick and `activeVersionLabel`; the Apple TV host reads it before advancing).

- [ ] **Step 1: Write failing tests.** `test_start_multipleSources_setsActiveVersionLabel` ("1080p" when `movie-1-1080p` requested); `test_start_singleSource_versionLabelNil`; `test_nextItemVersionChoice_sameLabel_plays` (next episode with no preference, current "1080p" → `.play(<id>-1080p)`); `test_nextItemVersionChoice_noMatch_asks`; `test_nextItemVersionChoice_singleVersionNext_plays`; `test_statsReport_versionRowOnlyWithLabel`.
- [ ] **Step 2:** Run them; expect FAIL.
- [ ] **Step 3: Implement.** `/PlaybackInfo` filtered by `MediaSourceId` returns one source, so the labels can't come from it: use `mediaItem.dto.mediaSources` (fetched with `detailFields`, which carries `MediaSources`). Wire `previousVersionLabel` where iOS auto-advance builds requests: `ShowDetailView.swift:339`, `PlaylistDetailView.swift:133`. The page runs `continuation` on it, and an `.ask` goes to Task 4's dialog. The Apple TV's in-place advance (`TVPlayerHostController.advanceToNextItem`) is wired in Task 6.
- [ ] **Step 4:** Run; expect PASS. Both schemes' unit tests for these files.

### Task 4: iOS: one question for every user-started play

**Files:**
- Create: `DionysusPlayer/Features/AssetDetails/Components/VersionChoiceDialog.swift`
- Modify: `PlayResumeButtonRow.swift` (adopt the modifier; behaviour unchanged except for D8's mark), `AssetDetailViewModel.swift`, `MovieDetailView.swift`, `ShowDetailView.swift` (episode rows via `onPlayEpisode`), `CollectionDetailView.swift`, `PlaylistDetailView.swift` (D1)
- Modify: `AccessibilityIdentifiers.swift`
- Test: `DionysusPlayerTests/Features/AssetDetails/AssetDetailViewModelTests.swift`; `DionysusPlayerUITests/Journeys/MediaVersionJourneyTests.swift` (new)

**Interfaces:**
- Consumes: `MediaVersionChoice` (Task 1), `.multipleVersions` (Task 2), the Stats version row (Task 3)
- Produces:
  - `AssetDetailViewModel.playbackDecision(for item: MediaItem, isResume: Bool) async -> MediaVersionChoice`, which fetches `item(userID:itemID:)` when `item.dto.mediaSources == nil` (list rows) and falls back to `.play(nil)` if that fetch fails. Shared, so the Apple TV uses it too.
  - `View.versionChoiceDialog(_ pending: Binding<PendingVersionChoice?>, onChoose: @escaping (String) -> Void) -> some View`, where `struct PendingVersionChoice: Identifiable { let id = UUID(); let versions: [MediaVersion]; let lastPlayedID: String? }` lives in `Core/Models/MediaVersionChoice.swift`, since the Apple TV compiles `Core/` but not iOS components. Title "Choose a Version". Each button reads `label` or "\(label) (Last Played)" and carries `A11yID.Versions.option(version.id)`.
  - Choosing calls `setPreferredMediaSourceID` (as today), then plays.

- [ ] **Step 1: Unit tests** (fail first): `test_playbackDecision_listItemWithoutSources_fetchesFullItem`; `test_playbackDecision_fetchFails_playsServerDefault`; `test_playbackDecision_resume_usesStoredPreference`.
- [ ] **Step 2: Journeys** in `MediaVersionJourneyTests` (scenario `.multipleVersions`), red until Step 3:
  - `test_play_unwatchedMultiVersionMovie_asks_andPlaysTheChosenVersion`: movie-1 → Play → `Versions.option("movie-1-1080p")` → open Playback Stats → `versionValue` reads "1080p"
  - `test_restart_asks_thenResume_playsTheRememberedVersionWithoutAsking`: movie-2 → Restart → Director's Cut → close the player → Resume → no `Versions.option` element appears → Stats reads "Director's Cut"
  - `test_play_lastPlayedIsMarked`: after the previous journey's choice, Restart shows the option with `movie-2-directors-cut` (assert by id only)
  - `test_play_cancel_playsNothing`: dismiss the dialog → no player
  - `test_episodeRowPlay_asks` (D1): show → Season 1 → episode 2's row Play → the dialog appears
  - `test_resume_noRememberedVersion_asks_andRemembers` (D4): episode-s1e1 (part-watched, nothing remembered) → Resume → dialog → 4K HDR10 → close → Resume again → no dialog
  - `test_autoAdvance_sameLabel_doesNotAsk` and `test_autoAdvance_noMatchingVersion_asks` (D2): S2:E1 in 1080p → let Next Up advance (`-UITestShortPlayerTimers`) → S2:E2 (editions) shows the dialog; S1:E1 → S1:E2 plays 1080p without it
  - `test_singleVersionMovie_playsWithoutAsking` (regression, `.standard`)
- [ ] **Step 3: Implement**, then run both test sets; expect PASS. Check whether `confirmationDialog` buttons expose `accessibilityIdentifier` on iOS 27 and 18.6. If not on either, the journeys fall back to the unlocalized technical labels ("1080p"), and the plan records why.
- [ ] **Step 4:** Screenshot the dialog (iPhone 17) and send it to Benjamin **before** running wider suites (preference: show visual changes before tests).

### Task 5: Apple TV: version tabs in Details

**Files:**
- Modify: `DionysusTV/Browse/Detail/TVFullDetailsView.swift`, `TVDetailsPanel.swift`; `AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests` (a shared or tvOS-only test file for the sections builder); `DionysusTVUITests/DetailJourneyTests.swift`, `AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `MediaItem.mediaVersions`, `technicalDetails(forVersion:)`, the remembered pick through `AssetDetailViewModel.preferredMediaSourceID(forPlayableItem:)`
- Produces:
  - `TVFullDetailsView(item:initialVersionID:)`. With more than one version, a focusable row of version tabs sits under the title, one `Button` per version with `A11yID.TV.Detail.versionTab(id)`; the selected tab is marked (`.isSelected` trait, not colour alone). Only the selected version's Video/Audio/Subtitles sections show, with no " · label" suffix. About stays. Moving focus onto a tab selects it (tvOS tab-bar behaviour).
  - `static func TVFullDetailsView.sections(for item: MediaItem, versionID: String?) -> [Section]`, made `internal` for tests.
  - `TVDetailsPanel.rows(for:versionID:)` uses that version, and adds `("Versions", labels joined ", ")` when there are more than one (D10).

- [ ] **Step 1: Unit tests** (fail first): `test_sections_singleVersion_unchanged`; `test_sections_selectedVersionOnly_noSuffix`; `test_panelRows_multiVersion_addsVersionsRow`.
- [ ] **Step 2: Journeys** (`.multipleVersions`): `test_fullDetails_versionTabs_switchTheTechnicalSections` (movie-1 → Details → Select → tab `movie-1-1080p` → section `video.movie-1-1080p` exists, `video.movie-1-4k` doesn't); `test_fullDetails_singleVersion_hasNoTabs` (`.standard`). Add the multi-version full details to the Apple TV accessibility audit.
- [ ] **Step 3: Implement**, run; expect PASS. Screenshot on the Apple TV 4K (4th generation) Simulator for Benjamin before the wider suites.

### Task 6: Apple TV: the version question on play

**Files:**
- Create: `DionysusTV/Browse/Detail/TVVersionPickerPage.swift`
- Modify: `TVDetailActions.swift`, `TVPlaylistDetailView.swift`, `DionysusTV/Browse/Home/TVHomeView.swift` (D1), `DionysusTV/Player/TVPlayerHostController.swift` (D2), the Top Shelf's link builder (`DionysusTV/TopShelf/`) and `Core/DeepLinks/DeepLink.swift` (D3: `from=topshelf`), `DionysusTV/CLAUDE.md`, `TESTING.md`'s deep-link table
- Test: `DionysusTVUITests/MediaVersionJourneyTests.swift` (new); `AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `AssetDetailViewModel.playbackDecision(for:isResume:)` (Task 4), `PendingVersionChoice` (Task 4, in `Core/Models/MediaVersionChoice.swift`)
- Produces: `TVVersionPickerPage(title: String, choice: PendingVersionChoice, onChoose: (String) -> Void)`, a full-screen cover like `TVAddToPlaylistPage`. Heading "Choose a Version", the item's name beneath, one wide button per version (`A11yID.TV.versionOption(id)`). Focus starts on the last-played version, else the first. Menu closes it with nothing played. On the Home hero, which has no `AssetDetailViewModel`, a free function over `client` and `userID` makes the same decision: put `playbackDecision`'s body in a `MediaVersionResolver` struct both call.

- [ ] **Step 0: Unit tests** (fail first): `DeepLinkTests` `test_parse_fromTopShelf` and `test_build_topShelfLinkCarriesFrom` (round trip, and an old link without it still parses); `test_linkPlayback_fromTopShelf_freshStart_asks`, `test_linkPlayback_plainLink_neverAsks` on the shared link-routing code.
- [ ] **Step 1: Journeys** (fail first): `test_play_asks_andPlaysTheChosenVersion` (Stats `versionValue` reads "1080p"); `test_resume_doesNotAsk`; `test_menu_onTheQuestion_playsNothing_andFocusReturnsToPlay`; `test_homeHeroPlay_multiVersion_asks`; `test_autoAdvance_noMatchingVersion_asksOverThePlayer` (S2:E1 → Next Up → the picker appears over the player; Menu closes the player); `test_topShelfLink_freshStart_asks` (open `dionysus://play/movie-1?from=topshelf`); `test_plainPlayLink_doesNotAsk`. Audit the picker page.
- [ ] **Step 2: Implement**, run the journeys and `TVUnitTests`; expect PASS. Add a "Versions" note to `DionysusTV/CLAUDE.md` (the question is a page, not a dialog, and why).

### Task 7: iOS: version choice for a single download

**Files:**
- Modify: `DownloadButton.swift`, `AdvancedDownloadOptionsView.swift` (D9), `DownloadedItem.swift` (`var versionLabel: String?`), `DownloadManager.swift` (`enqueue(… versionLabel: String?)`), the downloaded-title Details (`DownloadedTechnicalDetailsView`: a "Version" row)
- Modify: `DOWNLOADS.md` (one paragraph: the version is chosen before the audio track; bulk rules)
- Test: `DionysusPlayerTests/Core/Downloads/DownloadManagerTests.swift`, `DownloadedItemTests.swift`; `DionysusPlayerUITests/Journeys/DownloadsJourneyTests.swift`

**Interfaces:**
- Consumes: `MediaVersion.versions(of:)`, `versionChoiceDialog` (Task 4)
- Produces: `DownloadManager.enqueue(item:mediaSource:versionLabel:audioTrack:subtitleTracks:resolution:preset:client:userID:)`, where `versionLabel` defaults to `nil` and is stored on the row. Flow: `/PlaybackInfo` (all sources) → with 2+ versions, the version dialog (D8 marks the remembered **playback** pick) → the existing audio prompt and subtitle warning over the **chosen** source. On the long-press path, the sheet's Version picker (seeded with the remembered or first version) replaces the dialog, and its size estimate follows the selection.

- [ ] **Step 1: Unit tests** (fail first): `test_enqueue_storesVersionLabel`; `test_retry_keepsSourceAndLabel`; `test_downloadedItem_versionLabelOptional_migratesNil` (an existing store row loads with `nil`).
- [ ] **Step 2: Journeys** (`.multipleVersions`): `test_download_multiVersionMovie_asksVersionThenAudio_andShowsVersionOnTheDownload` (choose 1080p → "ENG EAC3" → Downloads → title → Details → the Version row reads "1080p"); `test_download_cancelVersion_startsNothing` (the button returns to idle); `test_advancedOptions_hasVersionPicker_andSkipsTheDialog`.
- [ ] **Step 3: Implement**, run; expect PASS.

### Task 8: iOS: bulk season download

**Files:**
- Create: `DionysusPlayer/Core/Downloads/BulkVersionPlanner.swift`, `DionysusPlayer/Features/AssetDetails/Components/SeasonDownloadCoordinator.swift`, `BulkVersionChoiceSheet.swift`
- Modify: `SeasonDownloadButton.swift` (keeps its row/progress logic; hands scan, plan and enqueue to the coordinator)
- Test: `DionysusPlayerTests/Core/Downloads/BulkVersionPlannerTests.swift`, `DionysusPlayerTests/Features/AssetDetails/SeasonDownloadCoordinatorTests.swift` (new); `DownloadsJourneyTests.swift`

**Interfaces:**
- Consumes: `MediaVersion.versions(of:)`, `DownloadManager.enqueue(…versionLabel:…)` (Task 7)
- Produces:
  - `struct EpisodeScan { let episode: MediaItem; let sources: [MediaSourceInfo]; var versions: [MediaVersion] { MediaVersion.versions(of: sources) } }`
  - `enum BulkVersionPlan: Equatable { case noChoice; case uniform(labels: [String]); case perEpisode([String]) /* episode ids needing a pick, in season order */ }`
  - `static func BulkVersionPlanner.plan(_ scans: [EpisodeScan]) -> BulkVersionPlan`: only scans with 2+ versions count (D6). None → `.noChoice`. All with the same **ordered** label list → `.uniform`. Otherwise → `.perEpisode`.
  - `static func BulkVersionPlanner.source(in scan: EpisodeScan, forLabel label: String) -> MediaSourceInfo?` (single-version scans return their only source)
  - `@Observable @MainActor final class SeasonDownloadCoordinator`, initialised with `fetchSources: (String) async throws -> [MediaSourceInfo]` and `enqueue: (MediaItem, MediaSourceInfo, String?) async throws -> Void`. It has `phase: Phase` (`.idle`, `.scanning`, `.askingUniform([String])`, `.askingPerEpisode([EpisodeScan])`, `.queuing`), `func start(episodes:limit:)`, `func chooseUniform(_ label: String)`, `func choosePerEpisode(_ picks: [String: String] /* episodeID → sourceID */)`, `func cancel()` and `failureCount: Int`. Scanning keeps the existing bounded concurrency (`maxConcurrentDownloads`) and reuses the scan's sources to enqueue (no second `/PlaybackInfo`). Audio and subtitles are auto-picked as today.
  - UI: `.askingUniform` shows `confirmationDialog` "Download Season in Which Version?" with buttons `A11yID.Versions.bulkOption(label-index)`. `.askingPerEpisode` shows `BulkVersionChoiceSheet`: a list with one row per episode needing a pick ("S2:E2 · Episode 2" and a `.menu` `Picker`, `A11yID.Versions.bulkRowPicker(episodeID)`), defaulting to the remembered pick, else the first. Cancel and "Download N Episodes" (`A11yID.Versions.bulkDownloadButton`) sit in the toolbar with symbols and titles.

- [ ] **Step 1: Planner tests** (fail first): `test_plan_allSingleVersion_noChoice`; `test_plan_matchingLabels_uniform`; `test_plan_differentLabels_perEpisode`; `test_plan_sameLabelsDifferentOrder_perEpisode`; `test_plan_singleVersionEpisodesIgnored_uniform`; `test_plan_uniform_mapsDuplicateLabelsPerEpisode`; `test_source_singleVersionScan_returnsItsOnlySource`.
- [ ] **Step 2: Coordinator tests** (fail first): `test_coordinator_uniform_enqueuesChosenLabelForEach`; `test_coordinator_perEpisode_enqueuesEachPick`; `test_coordinator_noChoice_enqueuesWithoutAsking`; `test_coordinator_scanFailure_countsAndContinues`; `test_coordinator_cancel_enqueuesNothing_returnsIdle`; `test_coordinator_respectsConcurrencyLimit`.
- [ ] **Step 3: Journeys** (`.multipleVersions`): `test_seasonDownload_matchingVersions_asksOnce` (Season 1 → the season download button → pick 1080p → three rows, each episode's Details reads "1080p"); `test_seasonDownload_differingVersions_asksPerEpisode` (Season 2 → the sheet lists S2:E1 and S2:E2 only → pick Extended Edition for E2 → Download → E2's Version reads "Extended Edition"); `test_seasonDownload_cancel_startsNothing`; the sheet in `AccessibilityAuditTests`.
- [ ] **Step 4: Implement**, run; expect PASS. Screenshot both questions for Benjamin.

### Task 9: Docs, strings, full runs

**Files:** `CLAUDE.md` (a short "Versions" subsection under Architecture: the decision rule, D2/D3, where the question lives per platform), `TESTING.md`, `README.md` (review), `Localizable.xcstrings`

- [ ] **Step 1:** Write the docs. Sync the catalog with an Xcode.app build (the `automate-xcstrings-catalog-sync` memory has the method).
- [ ] **Step 2:** Run the four suites after Benjamin's sign-off on the diff: iOS `UnitTests`, iOS `UITests-Full`, `TVUnitTests`, `TVUITests`. All pass, or a failure is shown to fail on `develop` too.
- [ ] **Step 3:** Hand the diff to Benjamin. Commit, push and open the PR (base `develop`, closes #289) only on his word.

---

## Self-review notes

- Requirement coverage: 1 → Task 5; 2 → Tasks 4 and 6; 3 → Task 1 (rule), Tasks 4 and 6; 4 → Task 7; 5 → Task 8; 6 → this document.
- Each task stays shippable on its own: Tasks 1–3 change no UI behaviour except the Stats row. Tasks 4–8 each add one surface with its own journeys.
- Live checks on the real library (Benjamin's server has multi-version titles?) are not in the plan: there's no device step. If wanted, it goes in a Simulator check against SavareseHillFlix once a multi-version title is known there.
