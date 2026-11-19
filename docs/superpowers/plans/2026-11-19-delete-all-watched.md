# Delete All Watched Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A show's Delete menu gains "All Watched", which deletes every watched episode of the show (iOS and Apple TV) after a confirmation giving the counts.

**Architecture:** `AssetDetailViewModel` fetches the show's episodes (`CanDelete`, with UserData) whenever the page loads or refreshes and holds a `WatchedEpisodesDeletion` snapshot. `AssetActionTargets` turns it into a delete row alongside Show/Season/Episode through one new `AssetDeleteRequest` enum, so both platforms' menus and confirmations work from one list. Deletion reuses the folderless season's one-at-a-time path, generalised over a list of episodes.

**Tech Stack:** Swift 6, SwiftUI, XCTest/XCUITest, the in-process UI-test stub server, String Catalog.

**Spec:** `docs/superpowers/specs/2026-11-19-delete-all-watched-design.md`

## Global Constraints

- Branch `feature/437-delete-all-watched` off `develop`, in the main checkout (no worktree).
- **No `git commit` until Benjamin has seen the diff and said so.** Each task's last step stages and stops for sign-off.
- Watched = `UserData.Played == true`. A resume point alone isn't watched. Episodes with `locationType == "Virtual"` are in neither count.
- Row label "All Watched". Confirmation title "Delete Watched Episodes".
- Message (exact, Benjamin 2026-11-19): `"12 episodes that are watched will be deleted for all users. 28 episodes will remain for House of Games. This cannot be undone."` Singular forms: "1 episode that is watched will be deleted for all users." and "1 episode will remain for <show>." With none left: "No episodes will remain, and <show> will be removed."
- User-facing strings via `String(localized:)`. Plural variants hand-added to `DionysusPlayer/Resources/Localizable.xcstrings` (CI can't sync the catalog).
- Never select on a localized label in a journey (`A11yID`).
- During review rounds, run only new or changed tests. The four full suites run after sign-off, before the commit.

## Review Focus

1. Marking episodes watched with the eye menu, then opening Delete straight away: the count must include them (Task 2 reloads after `toggleWatched`).
2. Every episode watched: the show empties, Jellyfin drops it, and the page must pop rather than show a dead show (Task 2).
3. A watched episode with no file (`Virtual`, played) is counted in neither number and never sent a DELETE (Task 2).
4. A part-watched episode (resume point, not played) is never deleted (Task 2).
5. An episode page pushed on its own, whose episode is among those deleted, must pop, not stay on a deleted episode (Task 2).

---

### Task 1: The request type, its copy and the menu's targets

**Files:**
- Modify: `DionysusPlayer/Features/AssetDetails/AssetActionTargets.swift`
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings`
- Test: `DionysusPlayerTests/Features/AssetDetails/AssetActionTargetsTests.swift`

**Interfaces:**
- Produces:
  - `struct WatchedEpisodesDeletion: Equatable { let show: MediaItem; let watched: [MediaItem]; let totalCount: Int; var remainingCount: Int { totalCount - watched.count } }`
  - `enum AssetDeleteRequest: Identifiable, Equatable { case item(MediaItem); case watchedEpisodes(WatchedEpisodesDeletion) }` with `id: String` (`item.id`, or `"watched.\(show.id)"`), `rowLabel: String`, `actionLabel: String`, `confirmationMessage: String`, and `affectedItemIDs: [String]` (the item's id, or the watched episodes' ids; used for downloads on iOS).
  - `AssetActionTargets.init(…, playbackEpisode:, watchedEpisodes: WatchedEpisodesDeletion? = nil, canDeleteSeason:)` and `let deleteRequests: [AssetDeleteRequest]`. `deletable` is unchanged.
  - `static func deleteWatchedConfirmationMessage(for: WatchedEpisodesDeletion) -> String`

- [ ] **Step 1: Write the failing tests** in `AssetActionTargetsTests`:
  - `test_watchedEpisodes_sitsAfterTheShow`: the show, Season 1 and an episode deletable, plus a deletion. `deleteRequests.map(\.id) == ["show", "watched.show", "s1", "ep"]`.
  - `test_watchedEpisodes_leadsWhenTheShowIsNotDeletable`: show `canDelete: false`. `deleteRequests.first?.id == "watched.show"`.
  - `test_noWatchedEpisodes_offersNoRow`: `watchedEpisodes: nil`. `deleteRequests.map(\.id) == deletable.map(\.id)`.
  - `test_watchedRow_isNamedAllWatched`: `rowLabel == "All Watched"`, `actionLabel == "Delete Watched Episodes"`.
  - `test_watchedMessage_plural`: 12 watched of 40, show "House of Games". Equals the exact string in Global Constraints.
  - `test_watchedMessage_singular`: 1 of 2. `"1 episode that is watched will be deleted for all users. 1 episode will remain for House of Games. This cannot be undone."`
  - `test_watchedMessage_noneRemain`: 3 of 3. `"3 episodes that are watched will be deleted for all users. No episodes will remain, and House of Games will be removed. This cannot be undone."`
  - `test_itemRequest_keepsTodaysCopy`: `.item(season1)` gives `rowLabel` "Season 1", `actionLabel` "Delete Season", and the message `deleteConfirmationMessage(for:)` gives.

- [ ] **Step 2: Run them; expect a compile failure** (no `WatchedEpisodesDeletion`)

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AssetActionTargetsTests`

- [ ] **Step 3: Implement** the types above in `AssetActionTargets.swift`. `deleteRequests` is `deletable` mapped to `.item`, with `.watchedEpisodes` inserted after the series entry, or first when there's none. The message is three `String(localized:)` sentences joined with a space: `"\(count) episodes that are watched will be deleted for all users."`, then either `"\(remaining) episodes will remain for \(show.name)."` or, at zero, `"No episodes will remain, and \(show.name) will be removed."`, then `"This cannot be undone."`. Add `one`/`other` plural variations for the two counted keys to `Localizable.xcstrings` by hand (follow the shape of an existing plural entry there, or of Xcode's `variations.plural`).

- [ ] **Step 4: Run Step 2's command; expect PASS.** Also run `-scheme DionysusTV -testPlan TVUnitTests -only-testing:DionysusTVTests/AssetActionTargetsTests` on `'platform=tvOS Simulator,name=Apple TV 4K (4th generation)'` (the file is shared).

- [ ] **Step 5: Stage, and stop for Benjamin's sign-off before committing**

---

### Task 2: Loading the watched episodes and deleting them

**Files:**
- Modify: `DionysusPlayer/Features/AssetDetails/AssetDetailViewModel.swift` (Deletion section, `load()`, `refreshItem()`, `toggleWatched`)
- Test: `DionysusPlayerTests/Features/AssetDetails/AssetDetailViewModelTests.swift`

**Interfaces:**
- Consumes: `WatchedEpisodesDeletion`, `AssetDeleteRequest` (Task 1).
- Produces:
  - `private(set) var watchedEpisodes: WatchedEpisodesDeletion?`: nil off a show, with no watched episode, or when any watched episode has `canDelete == false`.
  - `func loadWatchedEpisodes() async`: one `client.episodes(seriesID:userID:fields: "CanDelete")` with no season. Called at the end of `load()` (series content), of `refreshItem()`, of a successful `toggleWatched`, and of `repairPage(removing:)`. A failed fetch leaves the previous value.
  - `func delete(_ request: AssetDeleteRequest) async throws -> DeletionOutcome`: `.item` forwards to `delete(_ target: MediaItem)`. `.watchedEpisodes` deletes the snapshot.
  - `PartialSeasonDeletionError` renamed `PartialDeletionError` (same fields and message). Existing tests updated.
  - `AssetActionTargets.init(viewModel:selectedSeasonID:)` passes `viewModel.watchedEpisodes`.

- [ ] **Step 1: Write the failing tests.** Stub a show of 2 seasons with `/Shows/series-1/Episodes` (no `seasonId`) answering: s1e1 played, s1e2 played, s1e3 resume point only, s2e1 played, s2e2 not played, s2e3 played but `Virtual`. All with files deletable unless a test says otherwise.
  - `test_loadWatchedEpisodes_countsPlayedEpisodesWithFiles`: `watched.map(\.id) == ["s1e1", "s1e2", "s2e1"]`, `totalCount == 5`.
  - `test_loadWatchedEpisodes_nilWhenAWatchedEpisodeIsNotDeletable`: s1e2 `canDelete: false` gives nil.
  - `test_loadWatchedEpisodes_nilWhenNothingIsWatched`.
  - `test_toggleWatched_reloadsWatchedEpisodes`: after the stub flips s2e2 to played and `toggleWatched(itemID: "s2e2", currentlyWatched: false)` succeeds, `watched.count == 4`. (Review Focus 1)
  - `test_deleteWatched_deletesOnlyTheSnapshot`: DELETE paths `== ["/Items/s1e1", "/Items/s1e2", "/Items/s2e1"]`; s1e3 and s2e3 never sent (Review Focus 3, 4). Outcome `.stayAndRefresh`.
  - `test_deleteWatched_dropsAnEmptiedSeason`: with s1e3 also played, Season 1 leaves `seasons` though the stub still lists it.
  - `test_deleteWatched_stopsAtTheFirstFailure`: s1e2 answers 500. Throws `PartialDeletionError(deletedCount: 1, totalCount: 3)`, and the reloaded `watchedEpisodes` no longer holds s1e1.
  - `test_deleteWatched_everyEpisode_popsOffTheEmptiedShow`: all watched; series fetch after deletion answers 404. From the show's page `.popOneLevel`; from a page loaded with `itemID` of an episode, `.popToRoot` (Review Focus 2).
  - `test_deleteWatched_fromAPushedEpisodeAmongThem_popsOneLevel`: page loaded on s1e1, show not emptied. `.popOneLevel` (Review Focus 5).
  - `test_deleteWatched_announcesOnce`: `DeletedItemBroadcaster.shared.lastDeletedItemID` is the last episode deleted.

- [ ] **Step 2: Run them; expect failure**

Run: `xcodebuild test … -only-testing:DionysusPlayerTests/AssetDetailViewModelTests`

- [ ] **Step 3: Implement.** Pull `deleteEpisodeByEpisode`'s loop into `private func deleteEpisodes(_ episodes: [MediaItem]) async throws -> Set<String>`: sequential, plain error on the first, `PartialDeletionError` (with the page repaired and the last deleted id announced) after that. The folderless season and `.watchedEpisodes` both use it. After a full watched deletion: put every season whose file episodes were all in the snapshot into `emptiedSeasonIDs`, announce the last episode once, then resolve the outcome. If the series fetch fails or `recursiveItemCount == 0`, return `.popOneLevel` when `itemID == seriesID`, else `.popToRoot`. Otherwise `.popOneLevel` if the page's own episode (`item?.id == itemID`) was deleted, else `.stayAndRefresh` with `repairPage(removing:)`. Track the pending state as `deletingItemIDs.insert("watched.\(show.id)")`.

- [ ] **Step 4: Run Step 2's command; expect PASS**, including the renamed folderless-season tests.

- [ ] **Step 5: Stage, and stop for sign-off**

---

### Task 3: iOS menu, confirmation and journey

**Files:**
- Modify: `DionysusPlayer/Features/AssetDetails/Components/AssetActionsButton.swift`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.AssetDetail.deleteWatchedButton`)
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift`, `UITestFixtureLibrary.swift` (scenario `watchedEpisodes`)
- Modify: `DionysusPlayerUITests/Screens/Screens.swift`, `DionysusPlayerUITests/Journeys/AssetDetailJourneyTests.swift`
- Modify: `TestPlans/UITests-Full.xctestplan` only if journeys are listed by name there

**Interfaces:**
- Consumes: `AssetActionTargets.deleteRequests`, `AssetDeleteRequest`, `viewModel.delete(_: AssetDeleteRequest)`.
- Produces: scenario `watchedEpisodes`, `.standard`'s catalogue with every Season 1 episode played (no resume point), used by Task 4 too.

- [ ] **Step 1: Write the failing journey** `testDeletingAllWatchedEpisodesLeavesTheRest`. Launch the `watchedEpisodes` scenario and open the series from the Shows library. `openDelete()`, then tap `app.buttons[A11yID.AssetDetail.deleteWatchedButton]`. The confirmation's message contains `"3 episodes"` and `"3 episodes will remain for \(UITestFixtureIdentity.seriesName)"`. `confirmDelete()`. Then: the Season 2 Episode 1 row exists; no Season 1 Episode 1 row; `playButton.label` doesn't contain `"S1:E"`. (The message check reads text the stub's numbers fix, matching on the counts and the stub's show name, not the localized words alone.)

- [ ] **Step 2: Run it; expect failure**

Run: `xcodebuild test … -testPlan UITests-Full -only-testing:DionysusPlayerUITests/AssetDetailJourneyTests/testDeletingAllWatchedEpisodesLeavesTheRest`

- [ ] **Step 3: Implement.**
  - Add the scenario: in `episodes`, `played: true` and a position of 0 for Season 1 under `.watchedEpisodes`. Add its row to `TESTING.md`'s scenario table.
  - `AssetActionsButton`: `pendingTarget` becomes `AssetDeleteRequest?`. The submenu iterates `targets.deleteRequests` (`rowLabel`). The watched row carries `deleteWatchedButton`. One row stays flat (`actionLabel`). The dialog title and message come from the request. `downloadedItemIDs(under:)` takes the request: for `.watchedEpisodes`, the store's items whose `itemID` is in `affectedItemIDs`. `perform` calls `viewModel.delete(request)`.

- [ ] **Step 4: Run Step 2's command, plus `testFolderlessSeasonIsDeletedEpisodeByEpisode` and the other `AssetDetailJourneyTests` delete journeys; expect PASS.** Screenshot the menu and the confirmation on iPhone 17 for Benjamin before going on (look-change rule).

- [ ] **Step 5: Stage, and stop for sign-off**

---

### Task 4: Apple TV menu, confirmation and journey

**Files:**
- Modify: `DionysusTV/Browse/Detail/TVMoreActionsButton.swift`
- Modify: `DionysusTVUITests/MoreActionsJourneyTests.swift`

**Interfaces:**
- Consumes: Task 1's `deleteRequests`/`AssetDeleteRequest`, Task 2's `delete(_: AssetDeleteRequest)`, Task 3's `watchedEpisodes` scenario. `A11yID.TV.Actions.delete(request.id)` for the row (`"watched.series-…"`).

- [ ] **Step 1: Write the failing journey** `test_deleteAllWatched_leavesTheUnwatchedSeason`. `launchAtHome(scenario: "watchedEpisodes")`, `openSeries`, `openDeleteSubmenu`. The watched row is the cell whose identifier contains `".watched."`. On tvOS 27, where submenu rows have no identifiers, it's the row between `seriesRow` and `seasonRow` by `frame.minY`. Never select it by its localized label. `confirmDelete(app, row:)`. Then: `episodeTile(app, season: 2, 1)` appears within 10s, `episodeTile(app, season: 1, 1)` doesn't exist, `A11yID.TV.Detail.season("season-1")` is gone, Play still exists, and focus returns to More.

- [ ] **Step 2: Run it; expect failure**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' -only-testing:DionysusTVUITests/MoreActionsJourneyTests/test_deleteAllWatched_leavesTheUnwatchedSeason`

- [ ] **Step 3: Implement.** `TVMoreActionsCover.confirmDelete` and `confirmedDeletion` carry `AssetDeleteRequest`. `deleteContent` iterates `targets.deleteRequests`. `TVConfirmation` takes `actionLabel`/`confirmationMessage`. `delete(_:)` calls `viewModel.delete(request)`. The page's existing `episodeListRefreshToken` handler already retains only seasons that remain.

- [ ] **Step 4: Run Step 2's command and the rest of `MoreActionsJourneyTests`; expect PASS.** Screenshot the submenu and question for Benjamin.

- [ ] **Step 5: Stage, and stop for sign-off**

---

### Task 5: Docs, then the full suites

**Files:**
- Modify: `CLAUDE.md` ("Deleting a season": a short "Deleting a show's watched episodes" paragraph covering the snapshot, the one-at-a-time path, "for all users", and emptied seasons dropping off)
- Modify: `DionysusTV/CLAUDE.md` (More Actions: All Watched sits after the show; how the journey finds its row on tvOS 27)
- Modify: `TESTING.md` (scenario row, done in Task 3), `README.md` (feature list, if it lists Delete)

- [ ] **Step 1: Write the doc changes**, and check that `Localizable.xcstrings` holds every new key (Cmd+B in Xcode per the catalog-sync memory, or confirm the hand-added entries).
- [ ] **Step 2: After Benjamin signs off, run all four suites** (UnitTests, UITests-Full journeys touched, TVUnitTests, TVUITests `MoreActionsJourneyTests`). Run them one at a time, never concurrently. Expect PASS.
- [ ] **Step 3: Commit on his word, then open the PR against `develop`** (closes #437; concise body; no session URL).
