# Up Next for Downloads, with Delete & Play Next — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A downloaded episode cues up the immediate next downloaded episode, and its Up Next card offers Cancel and Delete & Play Next (#274).

**Architecture:** Each new download records where the server's next episode is. A pure rule (`DownloadedNextEpisode`) finds the immediate next download offline. `PlayerViewModel.startOffline` uses it to fill `nextEpisode`. `NextUpOverlay` swaps Play Now for Delete & Play Next on offline sessions. `DownloadedAssetDetailView` chains episodes the way `ShowDetailView` does: it deletes the finished download after the player has closed, switches its subject to the next episode and presents the player again.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`DownloadedItem`), XCTest, XCUITest. iOS only: everything sits behind `#if DOWNLOADS` or in iOS-only files.

**Spec:** `docs/superpowers/specs/2026-11-20-delete-and-play-next-design.md`

## Global Constraints

- iOS/iPadOS only. Shared files (`PlayerViewModel`) guard every Downloads type with `#if DOWNLOADS`; the tvOS build must still compile.
- Delete only on an explicit tap of Delete & Play Next. The countdown, Cancel and closing the player never delete.
- `DownloadManager.delete(itemID:)` is the only delete: the device's copy, never the server's.
- No gap skipping: no Up Next unless the immediate next episode is downloaded.
- Specials (season 0), unnumbered episodes and movies never cue, and never get cued.
- Card on an offline session: two buttons, Cancel and "Delete & Play Next" (`trash` symbol, `.borderedProminent`, in Play Now's place). Streamed sessions keep Cancel and Play Now.
- VoiceOver hint on the button: "Deletes this episode's download from this device."
- New strings go through `Localizable.xcstrings` (`String(localized:)` outside views), synced in the same branch (Xcode.app build).
- Old downloads have no record: same-season cueing only.
- Never select on an accessibility label in UI tests; never put an identifier on a screen-root container.
- Run `xcodegen generate` after adding source files.
- Each task's "Commit" step needs Benjamin's sign-off first (his standing rule); push and the PR need it too.

## Review Focus

1. **The next download isn't playable** (still downloading, failed, or `markedForDeletion`): no card. Pinned in Task 2.
2. **Another user's download on the same device** for the same show: never cued. Pinned in Task 2.
3. **The countdown and the tap land together**: `PlayerView.tearDown`'s `isTearingDown` guard means the first one wins, and the delete happens at most once. Pinned in Task 5 (`resolve` called once per staged advance; the stage is cleared before acting).
4. **The deleted episode's watched mark hasn't synced yet**: the row must survive as `markedForDeletion`, with `isPlayed` kept. Pinned in Task 5.
5. **The next download disappears between the cue and the dismiss**: no "no longer available" page. Pinned in Task 5.

---

### Task 1: Record the next episode at download time

**Files:**
- Modify: `DionysusPlayer/Core/Networking/JellyfinModels.swift` (`BaseItemDto`: add `indexNumberEnd: Int?`, coding key `IndexNumberEnd`)
- Modify: `DionysusPlayer/Core/Downloads/DownloadedItem.swift` (new stored properties and `init` parameters)
- Modify: `DionysusPlayer/Core/Downloads/DownloadManager.swift` (`enqueue`)
- Test: `DionysusPlayerTests/Core/Downloads/DownloadManagerTests.swift`

**Interfaces:**
- Produces on `DownloadedItem`:
  - `var episodeNumberEnd: Int?`: `IndexNumberEnd`; `nil` for a single episode.
  - `var hasNextEpisodeRecord: Bool = false`: `true` once the lookup succeeded.
  - `var nextEpisodeSeasonNumber: Int?` and `var nextEpisodeNumber: Int?`: the server's next episode. Both `nil` with `hasNextEpisodeRecord == true` means the series ends here.
  - The `init` takes all four as trailing defaulted parameters (`nil`, `false`, `nil`, `nil`).
- All four are defaulted or optional, so SwiftData migrates old rows without a migration plan.

- [ ] **Step 1: Write the failing tests** in `DownloadManagerTests`, using the file's existing `MockURLProtocol` enqueue setup:
  - `test_enqueue_episode_recordsTheServersNextEpisode`: E2 of a season answering E1–E3 → `hasNextEpisodeRecord == true`, `nextEpisodeSeasonNumber == 1`, `nextEpisodeNumber == 3`.
  - `test_enqueue_seasonFinale_recordsNextSeasonsFirstEpisode`: E3 of S1, seasons S1/S2, S2's first episode is E1 → `(2, 1)`.
  - `test_enqueue_seriesFinale_recordsNoNextEpisode`: last episode of the last season → `hasNextEpisodeRecord == true`, both numbers `nil`.
  - `test_enqueue_whenLookupFails_stillDownloads_withoutARecord`: the episodes request answers 500 → the row exists, `hasNextEpisodeRecord == false`.
  - `test_enqueue_doubleEpisode_storesItsLastNumber`: DTO with `IndexNumberEnd: 2` → `episodeNumberEnd == 2`.
  - `test_enqueue_movie_makesNoLookup`: no `/Shows/` request is made.
- [ ] **Step 2: Run them and see them fail**
  Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/DownloadManagerTests`
  Expected: compile failure (the new properties don't exist yet).
- [ ] **Step 3: Implement.** In `enqueue`, for an episode with `seriesId` and `seasonId`, call `client.nextEpisode(currentEpisodeID:seriesID:seasonID:userID:)` inside `try?`. On success, set the record from the answer's `parentIndexNumber`/`indexNumber`; a `nil` answer means the series ends here. On a throw, leave no record. Never let the lookup fail the download. Store `item.dto.indexNumberEnd` in `episodeNumberEnd`.
- [ ] **Step 4: Run the tests and see them pass** (same command). Expected: PASS.
- [ ] **Step 5: Commit**: `Record the next episode on each download (#274)`

### Task 2: The immediate-next rule

**Files:**
- Create: `DionysusPlayer/Core/Downloads/DownloadedNextEpisode.swift`
- Test: `DionysusPlayerTests/Core/Downloads/DownloadedNextEpisodeTests.swift`

**Interfaces:**
- Consumes: Task 1's fields.
- Produces: `enum DownloadedNextEpisode { static func find(after current: DownloadedItem, among items: [DownloadedItem]) -> DownloadedItem? }`

The rule (pure; `among` may include `current`):
- `current` qualifies only as an episode with `seriesID`, `seasonNumber > 0` and `episodeNumber`. Its last number is `episodeNumberEnd ?? episodeNumber`.
- A candidate qualifies only if it is an episode of the same `seriesID` and `userID`, with `status == .completed`, `!markedForDeletion`, `seasonNumber > 0` and an `episodeNumber`.
- The target is (season, episode):
  - With a record, `(nextEpisodeSeasonNumber, nextEpisodeNumber)`; both `nil` means `nil`.
  - Without one, `(current.seasonNumber, last + 1)`, matched within the same `seasonID`.
- Return the candidate whose `(seasonNumber, episodeNumber)` equals the target, else `nil`.

- [ ] **Step 1: Write the failing tests.** Extend `DownloadTestHelpers.makeItem` with defaulted `kind`, `seriesID`, `seasonID`, `seasonNumber`, `episodeNumber`, `episodeNumberEnd`, `userID` and the record fields, defaulting to today's values. One test each:
  - `test_sameSeason_nextNumber_isFound`: S1E1 → S1E2.
  - `test_gap_findsNothing`: S1E1 with only S1E3 → `nil`.
  - `test_doubleEpisode_continuesAfterItsLastNumber`: S1E1–E2 → S1E3.
  - `test_seasonFinale_withRecord_findsNextSeason`: S1E3, record `(2, 1)` → S2E1.
  - `test_seasonFinale_withoutRecord_findsNothing`: S1E3, no record, S2E1 present → `nil`.
  - `test_recordSkippingASeason_findsNothingWhenThatSeasonIsMissing`: record `(2, 1)` with only S3E1 → `nil`.
  - `test_seriesFinale_record_findsNothing`.
  - `test_special_neverCues_andIsNeverCued`: S0E1 → `nil`; S1E1 with record `(0, 1)` → `nil`.
  - `test_unnumbered_findsNothing`.
  - `test_incompleteOrMarkedForDeletionNext_isSkipped`: `.downloading`, `.failed`, `markedForDeletion` → `nil`.
  - `test_otherUsersDownload_isNotCued`.
  - `test_otherSeries_isNotCued`.
- [ ] **Step 2: Run them and see them fail** (`-only-testing:DionysusPlayerTests/DownloadedNextEpisodeTests`; run `xcodegen generate` first). Expected: compile failure.
- [ ] **Step 3: Implement `find(after:among:)`** as specified.
- [ ] **Step 4: Run and see them pass.** Expected: PASS.
- [ ] **Step 5: Commit**: `Find the immediate next downloaded episode (#274)`

### Task 3: Up Next on offline sessions (`PlayerViewModel`)

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift` (`startOffline`, its doc comment, new properties, all inside `#if DOWNLOADS`)
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelOfflineTests.swift`

**Interfaces:**
- Consumes: `DownloadedNextEpisode.find(after:among:)`, `DownloadStore.allItems()`.
- Produces:
  - `private(set) var nextEpisodeImageFileURL: URL?`: the next download's `thumbImagePath ?? backdropImagePath ?? posterImagePath` as a file URL. Declared outside `#if` (always `nil` on tvOS), so `PlayerView` can read it unguarded.
  - `var offersDeleteAndPlayNext: Bool`: `isOfflinePlayback && nextEpisode != nil`. Also outside `#if`.
  - `nextEpisode` is set offline to a `MediaItem` built from the next download the same way `startOffline` builds `item`. Move that `BaseItemDto`/`MediaItem` construction into `private static func offlineMediaItem(for: DownloadedItem) -> MediaItem` and use it for both.

- [ ] **Step 1: Write the failing tests:**
  - `test_startOffline_withImmediateNextDownload_setsNextEpisode`: store S1E1 and S1E2 (both `.completed`) → `nextEpisode?.id == "s1e2"`, `offersDeleteAndPlayNext == true`, `closesWhenPlaybackEnds == false`.
  - `test_startOffline_withGap_leavesNextEpisodeNil`: store S1E1 and S1E3 → `nextEpisode == nil`, `offersDeleteAndPlayNext == false`, `closesWhenPlaybackEnds == true`.
  - `test_startOffline_nextEpisodeImage_isTheNextDownloadsThumb` → `nextEpisodeImageFileURL == DownloadFileStore.url(forRelativePath: next.thumbImagePath!)`.
  - `test_startOffline_stillNeverHitsTheNetwork_withANextDownload` (the existing `MockURLProtocol` handler throws, so any request fails the test).
  - In `PlayerViewModelTests`, `test_onlineSession_neverOffersDeleteAndPlayNext`: a live session with a `nextEpisode` → `false`.
- [ ] **Step 2: Run and see them fail** (`-only-testing:DionysusPlayerTests/PlayerViewModelOfflineTests`). Expected: FAIL / compile failure.
- [ ] **Step 3: Implement.** In `startOffline`, after `item` is set: if `downloadStore` is non-nil, `find` the next download among `allItems()`, then set `nextEpisode` and `nextEpisodeImageFileURL` from it. Update the doc comment: offline now resolves Up Next locally.
- [ ] **Step 4: Run and see them pass**, then build the tvOS scheme so nothing outside `#if DOWNLOADS` names a Downloads type:
  `xcodebuild build -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)'`. Expected: BUILD SUCCEEDED.
- [ ] **Step 5: Commit**: `Cue the next downloaded episode offline (#274)`

### Task 4: The card and the player's callback

**Files:**
- Modify: `DionysusPlayer/Features/Player/NextUpOverlay.swift`
- Modify: `DionysusPlayer/Features/Player/PlayerView.swift` (`NextUpOverlay` call, `advanceToNextItem`, `tearDown`, new callback)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Player.nextUpDeleteAndPlayNext = "player.nextUp.deleteAndPlayNext"`)
- Modify: `DionysusPlayerUITests/Screens/Screens.swift` (`PlayerScreen.nextUpDeleteAndPlayNext`)
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `offersDeleteAndPlayNext`, `nextEpisodeImageFileURL` (Task 3).
- Produces:
  - `NextUpOverlay` gains `var imageFileURL: URL? = nil` (non-nil draws `LocalFileImage(url:placeholderSystemImage: "play.tv")` instead of `AsyncRemoteImage`) and `var onDeleteAndPlayNext: (() -> Void)? = nil` (non-nil replaces Play Now with Delete & Play Next).
  - `PlayerView` gains `var onRequestNextDownload: ((_ itemID: String, _ deletesFinished: Bool) -> Void)? = nil`. When `downloadedItem != nil`, `tearDown(nextItemID:)` calls it instead of `onRequestNextItem`.
  - `advanceToNextItem(deletingFinished: Bool = false)`: Delete & Play Next passes `true`; the countdown's `.onChange` and Play Now keep `false`.

- [ ] **Step 1: Implement the card.** In Play Now's slot: `Button(action:) { Label("Delete & Play Next", systemImage: "trash") }`, `.borderedProminent`, identifier `A11yID.Player.nextUpDeleteAndPlayNext`, `.accessibilityHint("Deletes this episode's download from this device.")`. Check that it fits beside Cancel in the 260pt card at the default text size and at AX sizes in the iPhone 17 Simulator (the `earlyCredits` offline flow from Task 6, or a preview). If it doesn't fit, stack the two buttons vertically, full width, at accessibility sizes only. Never let the label collapse to the symbol alone.
- [ ] **Step 2: Wire `PlayerView`.** Pass `imageFileURL: viewModel.nextEpisodeImageFileURL` and `onDeleteAndPlayNext: viewModel.offersDeleteAndPlayNext ? { Task { await advanceToNextItem(deletingFinished: true) } } : nil`. Thread `deletingFinished` through `tearDown`.
- [ ] **Step 3: Build iOS and tvOS.** Expected: both BUILD SUCCEEDED. Run the existing `NextUpOverlay`/Player unit tests: PASS.
- [ ] **Step 4: Sync the String Catalog** (`automate-xcstrings-catalog-sync` memory: Xcode.app Cmd+B). Check that the diff has "Delete & Play Next" and the hint.
- [ ] **Step 5: Screenshot the card in the Simulator for Benjamin and wait for his OK before Task 6's journeys** (his standing preference: visual changes before tests).
- [ ] **Step 6: Commit**: `Offer Delete & Play Next on a download's Up Next card (#274)`

### Task 5: The episode page chains downloads

**Files:**
- Create: `DionysusPlayer/Features/Downloads/DownloadedEpisodeAdvance.swift`
- Modify: `DionysusPlayer/Features/Downloads/DownloadedAssetDetailView.swift`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Downloads.detailHero(_ itemID: String) -> String`, `"downloads.detail.hero.\(itemID)"`, on the page's `HeroHeaderView`, not the root)
- Test: `DionysusPlayerTests/Features/Downloads/DownloadedEpisodeAdvanceTests.swift`

**Interfaces:**
- Consumes: `PlayerView.onRequestNextDownload` (Task 4), `DownloadManager.delete(itemID:)`.
- Produces:
  ```swift
  struct DownloadedEpisodeAdvance: Equatable { let finishedItemID: String; let nextItemID: String; let deletesFinished: Bool }
  enum DownloadedEpisodeAdvanceOutcome: Equatable { case play(String), stay(String), leave }
  extension DownloadedEpisodeAdvance {
      @MainActor func resolve(store: DownloadStore, delete: (String) -> Void) -> DownloadedEpisodeAdvanceOutcome
  }
  ```
  `resolve`: if `deletesFinished`, call `delete(finishedItemID)`. Then `.play(next)` if the store still has the next download, completed and not `markedForDeletion`. Otherwise `.stay(finished)` if the finished download is still there and not `markedForDeletion`, else `.leave`.

- [ ] **Step 1: Write the failing tests** (in-memory store; `delete` closure spy, or a real `DownloadManager` where the test needs the `markedForDeletion` behaviour):
  - `test_deleteAndPlayNext_deletesFinished_andPlaysNext` → spy called once with E1, outcome `.play("e2")`.
  - `test_countdown_deletesNothing_andPlaysNext` → spy never called, `.play("e2")`.
  - `test_nextGone_finishedKept_staysOnFinished` → `.stay("e1")`.
  - `test_nextGone_finishedDeleted_leaves` → `.leave`.
  - `test_deletingAnUnsyncedWatchedEpisode_keepsItsWatchedMarkUntilSync`: with a real `DownloadManager`, E1 `pendingSync = true`, `isPlayed = true` → after `resolve`, the row is `markedForDeletion` with `isPlayed == true`, and its video file is gone.
- [ ] **Step 2: Run and see them fail** (`xcodegen generate`, `-only-testing:DionysusPlayerTests/DownloadedEpisodeAdvanceTests`). Expected: compile failure.
- [ ] **Step 3: Implement `resolve`.**
- [ ] **Step 4: Wire the page.**
  - `@State private var shownItemID: String`, seeded from `itemID` in `init`. Every use of `itemID` in the body reads `shownItemID`. The deep-link cue keeps matching the route's `itemID`.
  - `@State private var pendingAdvance: DownloadedEpisodeAdvance?`, set by `onRequestNextDownload`.
  - The cover's `onDismiss`: bump `refreshTrigger`, take and clear `pendingAdvance`, then `resolve(store: downloadManager.store, delete: downloadManager.delete(itemID:))`.
    - `.play(id)`: `shownItemID = id`, `startFromBeginning = false`, `startSeconds = nil`, `linkOverrides = nil`, `isPlayerPresented = true`.
    - `.stay(id)`: `shownItemID = id`.
    - `.leave`: `dismiss()`.
  - Put `A11yID.Downloads.detailHero(item.itemID)` on the `HeroHeaderView`.
- [ ] **Step 5: Run the unit tests and the iOS build.** Expected: PASS, BUILD SUCCEEDED.
- [ ] **Step 6: Commit**: `Chain downloaded episodes from their page (#274)`

### Task 6: Journeys, audit and docs

**Files:**
- Modify: `DionysusPlayerUITests/Journeys/DownloadsJourneyTests.swift`
- Modify: `DionysusPlayerUITests/Journeys/PlayerJourneyTests.swift`
- Modify: `DionysusPlayerUITests/Journeys/AccessibilityAuditTests.swift`
- Modify: `DionysusPlayerUITests/Screens/Screens.swift` (`DownloadsScreen`/page helper for `detailHero`)
- Modify: `TESTING.md`, `DOWNLOADS.md`, `DionysusPlayer/Core/Playback/CLAUDE.md`

Setup for every offline journey: `launch(scenario: "earlyCredits")`, then download, `relaunchOffline()`, open the show's row and an episode row, and tap `A11yID.Downloads.playButton`. The download stores the scenario's credits at 0:05, so the card shows about 5 s in and counts down 10 s. If the stored segments don't carry over, add the credits to the download fixture rather than changing the online scenario.

- [ ] **Step 1: Write the journeys:**
  - `test_offlineNextUp_deleteAndPlayNext_playsTheNext_landsOnIt_andDeletesTheFinished`: `downloadSeasons(["season-1"])`, play S1E1 → the card shows `nextUpDeleteAndPlayNext` and `nextUpCancel`, with no `nextUpPlayNow`. Tap it → the player comes back near 0:00. Close → `detailHero(S1E2)` exists. Back → the S1E1 row is gone, and S1E2 and S1E3 rows exist.
  - `test_offlineNextUp_countdown_playsTheNext_andDeletesNothing`: same setup, let the countdown run (poll ≤ 20 s for position < 20). Close → `detailHero(S1E2)`. Back → the S1E1 row still exists.
  - `test_offlineNextUp_cancel_deletesNothing`: tap Cancel → the card goes; close → the S1E1 row still exists.
  - `test_offlineNextUp_gap_showsNoCard`: `download(S1E1)` and `download(S1E3)` only, play S1E1 → wait 10 s past the credits' start; the card never exists.
  - In `PlayerJourneyTests.testNextUpPlayNowPlaysTheNextEpisodeFromItsStart`, add `XCTAssertFalse(player.nextUpDeleteAndPlayNext.exists)` before tapping Play Now.
  - `AccessibilityAuditTests.testOfflineNextUpCardHasNoAccessibilityIssues`: the offline setup above, await the card, `try auditCurrentScreen()`.
- [ ] **Step 2: Run them** (`-only-testing:` each new test, iPhone 17). Expected: PASS. Then check each one fails with Task 5's `onDismiss` advance stubbed out (the land-on and delete assertions) and with the card's button removed.
- [ ] **Step 3: Docs.**
  - `TESTING.md`: list the journeys and the audit case.
  - `DOWNLOADS.md`: Up Next offline, the immediate-next rule, the four recorded fields (old downloads cue within a season), and that Delete & Play Next deletes the device's copy only, after the player has saved progress.
  - `Core/Playback/CLAUDE.md`: one paragraph on why the countdown never deletes and where the rule lives.
- [ ] **Step 4: Run the full suites.** These are `UnitTests` (iOS), `UITests-Smoke`, the Downloads and Player journey classes, and the tvOS `TVUnitTests` build (shared view model). Expected: all pass. Report any failure with its output.
- [ ] **Step 5: Commit**: `Journeys and docs for Delete & Play Next (#274)`. Then ask Benjamin to sign off before pushing or opening the PR.
