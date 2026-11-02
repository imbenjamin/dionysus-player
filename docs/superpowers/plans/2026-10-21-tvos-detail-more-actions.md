# Apple TV Detail "More Actions" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ellipsis` More Actions button after Favorite on the Apple TV's movie and show pages. It offers iOS's Add to Playlist and Delete (movie, show, season, episode), using the same targets, permissions, copy and server logic as iOS.

**Architecture:** iOS's overflow (`AssetActionsButton`) keeps three things in private view code: which targets it offers, its labels and its confirmation copy. Task 1 moves those into a UI-free `AssetActionTargets` that both apps compile. Everything below it is already shared and compiled on tvOS: `AssetDetailViewModel.delete(_:)` with its `DeletionOutcome`, folderless-season handling and page repair, and `AddToPlaylistViewModel`. On tvOS, the button opens a full-screen cover: a list of actions, the playlist picker and the new-playlist form, with `TVConfirmation` for the questions. Deleting pops through the shell (`TVShellNavigation`). A success toast reuses `ToastCenter`, newly compiled for tvOS.

**Tech Stack:** Swift 6, SwiftUI (tvOS 26.0 floor, built with Xcode 27.1), XCTest, XCUITest with the stub server, XcodeGen.

**Spec:** none separate. Benjamin asked for this on 2026-10-21 ("a '...' button next to the existing Favourite/heart button … the same logic should be reused from the iOS implementation"). The design calls are in **Decisions** below, for him to confirm when he reviews the plan.

## Decisions (confirm at review)

> **Revised during execution (Benjamin, 2026-10-21): Decisions 1 and 2 are
> superseded.** Shown the full-screen list, a system `Menu` throughout and a
> hybrid side by side, Benjamin chose the hybrid. ⋯ is a system `Menu` with
> iOS's shape: one target is a row, several make a submenu naming each, and
> Delete comes last below a divider. Add to Playlist opens the picker, and
> Delete opens its question, each as a full-screen cover that Menu closes
> onto ⋯. `TVAssetActionsPage` was never kept, and the cover enum lost its
> `.actions` case. The 1.3 s focus return after the menu closes is accepted
> for the native look. Task 4's text below describes the original list.

1. **The menu is our own full-screen cover, not a SwiftUI `Menu`.** `DionysusTV/CLAUDE.md` says a tvOS `Menu` hands focus back about 1.3 s after a choice, with nothing focused in between. That's why the pills and Profile's pickers are hand-made, and Profile's sub-screens are full-screen covers that Menu closes. Here, a `Menu` would also have to chain into a picker and a text form. The alternative is the system's `Menu` popover beside the button: the look is closer to iOS, but the focus gap comes back. Benjamin can overrule this, and if he does, Task 4 is the only task that changes.
2. **The menu is flat, with no submenus.** It has an "Add to Playlist" section and a "Delete" section. With one target, each section is a single row ("Add to Playlist", "Delete Episode"). With several, each row names its target as iOS's submenu rows do ("Breaking Bad", "Season 2", "S2:E4"). Delete comes last, as on iOS.
3. **Same scope as iOS.** The button goes on movie pages and on show pages (series, season, episode), never on box sets or playlists (`AssetActionsButton`'s doc says why). It is always drawn, because Add to Playlist has no permission gate, so the button never changes kind once `CanDelete` arrives.
4. **"This season" is the season on show** (`TVShowDetailView.seasonID`, the tab that last had focus), as on iOS, where it's the picker's selection. **"This episode" is offered only when the page is on an episode**, never for the episode Play would start (iOS's destructive-safety rule).
5. **No device copy on tvOS.** The delete confirmation is iOS's single "Delete" case. The "and Device" branch stays in the iOS view, behind downloads.
6. **Confirmations focus Cancel** (`TVConfirmation`, as Sign Out does). Adding a show or season to a playlist asks first, as on iOS. A single movie or episode is added at once.
7. **Success is a toast**: iOS's `ToastCenter`/`ToastHost`, compiled for tvOS and hosted once in `TVMainView`, with the same wording. It also makes the VoiceOver announcement.

## Global Constraints

- tvOS floor 26.0. Check focus behaviour on the tvOS 26 Simulator **and** the 27 one (`DionysusTV/CLAUDE.md`: they differ).
- Shared code must not name a Downloads type outside `#if DOWNLOADS`. `AssetActionTargets` names none.
- A shared view model's change ships on both platforms. This plan doesn't change `AssetDetailViewModel` or `AddToPlaylistViewModel`, only their callers.
- Strings: `String(localized:)` outside views, plain literals in views. Reuse iOS's existing strings wherever the wording matches ("More Actions", "Add to Playlist", "Delete", "Delete Show/Season/Episode", "New Playlist", "Couldn't delete", "Couldn't add to playlist", every confirmation and toast). Sync `Localizable.xcstrings` in the same PR (Xcode Cmd+B; hand-insert as a fallback).
- Never select on a label in UI tests. No identifier on a screen-root container. Decorative SF Symbols get `.accessibilityHidden(true)`.
- **A new file under `DionysusTV/` or a new include means `xcodegen generate`.**
- **Benjamin's workflow:** show a screenshot of each new screen (Simulator) and wait before running tests. No `git commit` until he has seen the diff and signed off. During review rounds, run only new and changed tests; run the full suites (iOS UnitTests, TVUnitTests, TV UI journeys, iOS smoke) after sign-off. Restore the Simulators' SavareseHillFlix sign-in before handing back.
- Branch: `feature/tv-detail-more-actions` off `develop`.

## Review Focus

1. **Deleting the episode the page is on, from a show page opened on the series.** The page must stay (`.stayAndRefresh`), fall back to the series with `chosenEpisodeID` cleared, and keep focus on More rather than on a vanished episode tile. Pinned in Task 5 (`test_deleteEpisode_pickedInPlace_staysOnTheShow`).
2. **Deleting the season on show.** The tabs must move to a remaining season (iOS's `onChange(of: seasons)` fix). A tab left on the deleted id lists it as empty under the next season's name. Pinned in Task 5 (`test_deleteSeason_movesTheTabsToARemainingSeason`).
3. **A user without delete rights** (`noDeletePermission`). More is still there, Add to Playlist is listed, and no Delete row or section heading appears. Pinned in Task 4 (`test_more_withoutDeletePermission_offersOnlyAddToPlaylist`).
4. **A folderless season** (`LocationType: Virtual`, `CanDelete: false`). It's offered once its episodes are known to be deletable, which needs `loadSeasonDeletability(seasonID:)` called on tvOS for the season on show. Pinned in Task 1 (`test_folderlessSeason_offeredOnlyWhenEveryEpisodeIsDeletable`) and wired in Task 5.
5. **Deleting the last episode of a show** (`.popToRoot`). The shell must drop the whole path, not just pop one page onto a show page that now answers 404. Pinned in Task 3 (`test_popToRoot_dropsEveryEntry`) and Task 5 (`test_deleteMovie_popsBackToTheGrid`, which covers the pop path).

---

### Task 1: Shared `AssetActionTargets`, with iOS moved onto it

**Files:**
- Create: `DionysusPlayer/Features/AssetDetails/AssetActionTargets.swift`
- Modify: `DionysusPlayer/Features/AssetDetails/Components/AssetActionsButton.swift` (remove `deletableTargets`, `playlistTargets`, `deleteActionLabel`, `menuRowLabel`, `confirmationMessage` and read them from the new type; `downloadedItemIDs` and the "and Device" button stay)
- Modify: `project.yml` (DionysusTV `DionysusPlayer/Features` includes: add `"AssetDetails/AssetActionTargets.swift"`)
- Test: `DionysusPlayerTests/Features/AssetDetails/AssetActionTargetsTests.swift` (already included in `DionysusTVTests` by `Features/AssetDetails/**`)

**Interfaces:**
- Produces:
  ```swift
  struct AssetActionTargets: Equatable {
      /// Most specific last: show, season, episode; or the lone movie.
      let deletable: [MediaItem]
      let addable: [MediaItem]
      init(item: MediaItem?, seriesItem: MediaItem?, seasons: [MediaItem],
           selectedSeasonID: String?, canDeleteSeason: (MediaItem) -> Bool)
      @MainActor init(viewModel: AssetDetailViewModel, selectedSeasonID: String?)
      static func deleteActionLabel(for target: MediaItem) -> String   // "Delete Show" / "Delete Season" / "Delete Episode" / "Delete"
      static func rowLabel(for target: MediaItem) -> String            // name; numberedEpisodeName for an episode
      static func deleteConfirmationMessage(for target: MediaItem) -> String
  }
  ```
  Move the doc comments from `AssetActionsButton` (the episode-only rule, the localization note on separate literals) with the code.

- [ ] **Step 1: Write the failing tests**, building `MediaItem`s with the existing test fixtures under `DionysusPlayerTests/Support`:
  - `test_movie_offersItselfForBoth`: `addable == [movie]`, `deletable == [movie]`.
  - `test_movieWithoutCanDelete_isAddableButNotDeletable`: `deletable.isEmpty`, `addable == [movie]`.
  - `test_seriesPage_offersShowAndSelectedSeason_neverAnEpisode`: item is the series, `selectedSeasonID` = S2. `addable.map(\.id) == [show, s2]`, with no episode.
  - `test_episodePage_offersShowSeasonEpisode_inThatOrder`.
  - `test_folderlessSeason_offeredOnlyWhenEveryEpisodeIsDeletable`: the season has `canDelete == false` and `canDeleteSeason` returns false, then true. Deletable without the season, then with it.
  - `test_copy`: `deleteActionLabel` for each kind. `deleteConfirmationMessage` for a season with `episodeCount == 6` contains "all 6 episodes", and without a count reads "all of its episodes".
- [ ] **Step 2: Run them and see them fail**: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AssetActionTargetsTests`. Expected: build failure, because `AssetActionTargets` doesn't exist.
- [ ] **Step 3: Implement `AssetActionTargets`.** The bodies are the ones in `AssetActionsButton` today. `init(viewModel:)` passes `viewModel.canDelete(season:)`.
- [ ] **Step 4: Move `AssetActionsButton` onto it.** Behaviour must not change.
- [ ] **Step 5: Run the new tests and iOS's existing guards**: `AssetActionTargetsTests`, `AssetDetailViewModelTests` and the iOS journeys `AssetDetailJourneyTests`, `AddToPlaylistJourneyTests`. Expected: all pass.
- [ ] **Step 6:** `xcodegen generate`, then build the `DionysusTV` scheme. Expected: it compiles.

### Task 2: Shared pieces made reusable on tvOS (confirmation, rows, toast)

**Files:**
- Create: `DionysusTV/Shell/TVConfirmation.swift`, moved out of `TVProfileView.swift`, where it's `private`
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift` (call sites)
- Modify: `DionysusTV/Shell/Profile/TVSettingsRow.swift` (verbatim-title init)
- Modify: `project.yml` (DionysusTV `DionysusPlayer/Shared` includes: add `"Components/Toast.swift"`)
- Modify: `DionysusPlayer/Shared/Components/Toast.swift` (a tvOS `navigationBarClearance` under `#if os(tvOS)`, if it needs one)
- Modify: `DionysusTV/Browse/TVMainView.swift` (host `ToastHost()` as an overlay above the pages and below the player)

**Interfaces:**
- Produces:
  - `TVConfirmation(title: Text, message: Text, action: Text, actionIdentifier: String, cancelIdentifier: String? = nil, isDestructive: Bool = true, onConfirm: () -> Void)`. Profile passes `Text("…")`, so its strings stay localized literals. `isDestructive: false` gives a plain button, for "Add 6 Episodes".
  - `TVSettingsRow.init(verbatimTitle: String, role: ButtonRole? = nil, identifier: String, action: @escaping () -> Void)` for rows titled with server content (a show's name).

- [ ] **Step 1:** Move and generalize `TVConfirmation`, keeping Cancel's default focus. Update Profile's two call sites.
- [ ] **Step 2:** Add the verbatim-title init to `TVSettingsRow`. Store the title as `Text`, so the accessibility label follows it unchanged.
- [ ] **Step 3:** Compile `Toast.swift` for tvOS, host `ToastHost` in `TVMainView`, and post a test toast from a `#if DEBUG` scratch call. Take a screenshot on the tvOS 27 Simulator, show Benjamin and wait. Remove the scratch call.
- [ ] **Step 4:** Run `ProfileJourneyTests` (Sign Out and Change Server confirmations). Expected: pass, since the confirmation moved without changing behaviour.

### Task 3: Shell pops for deletion outcomes

**Files:**
- Modify: `DionysusTV/Shell/TVShellNavigation.swift`
- Modify: `DionysusTV/Shell/TVRouteEnvironment.swift`
- Modify: `DionysusTV/Browse/TVMainView.swift`
- Test: `DionysusTVTests/TVShellNavigationTests.swift`

**Interfaces:**
- Produces:
  - `TVShellNavigation.popToRoot() -> [TVPathEntry]` (the entries removed, deepest first, so the caller can drop their models).
  - `EnvironmentValues.tvPopPage: @MainActor () -> Void` and `tvPopToRoot: @MainActor () -> Void`, set by `TVMainView` to its `pop()` and a new `popToRoot()`. `popToRoot()` cancels and drops `detailModels`, `pushedGrids` and `rememberedPushedFocus` for every entry removed, then calls `holdRail()`, as `pop()` does.

- [ ] **Step 1: Write failing tests:** `test_popToRoot_dropsEveryEntry` pushes three, `popToRoot()` returns three in the order deepest first, and `path.isEmpty`. `test_popToRoot_onTheRoot_returnsNothing`.
- [ ] **Step 2:** Run `-only-testing:DionysusTVTests/TVShellNavigationTests` on `platform=tvOS Simulator,name=Apple TV 4K (3rd generation)`. Expected: FAIL to build.
- [ ] **Step 3:** Implement both, with the environment entries and `TVMainView.popToRoot()`.
- [ ] **Step 4:** Run the same tests again. Expected: PASS.

### Task 4: The More button and the actions cover

**Files:**
- Create: `DionysusTV/Browse/Detail/TVMoreActionsButton.swift` (the button, the cover's presentation, running the delete and handling its outcome)
- Create: `DionysusTV/Browse/Detail/TVAssetActionsPage.swift` (the list of actions)
- Create: `DionysusTV/Browse/Detail/TVAddToPlaylistPage.swift` (the picker and the new-playlist form on `AddToPlaylistViewModel`)
- Modify: `DionysusTV/Browse/Detail/TVDetailActions.swift` (`TVDetailFocus.more = "action.more"`; `focusIDs` ends with `more` when the page shows it; replace the "There is no More button" doc line)
- Modify: `DionysusTV/Browse/Detail/TVMovieDetailView.swift` (pass `moreTargets`)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Detail.more`, plus a new `A11yID.TV.Actions`: `addToPlaylist(_ id:)`, `delete(_ id:)`, `deleteConfirm`, `newPlaylist`, `playlistRow(_ id:)`, `nameField`, `visibilityToggle`, `create`, `createConfirm`, `addConfirm`, `emptyState`)
- Test: `DionysusTVUITests/MoreActionsJourneyTests.swift` (new), `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `AssetActionTargets` (Task 1), `TVConfirmation`/`TVSettingsRow(verbatimTitle:)`/`ToastCenter` (Task 2), `tvPopPage`/`tvPopToRoot` (Task 3), `AssetDetailViewModel.delete(_:) -> DeletionOutcome`, `deletingItemIDs`, `AddToPlaylistViewModel`.
- Produces:
  - `TVDetailActions(…, moreTargets: AssetActionTargets?)`. `nil` draws no More button (box set and playlist pages don't use `TVDetailActions` today, but the parameter keeps the rule explicit). `focusIDs(playTarget:isResolving:hasMore:)`.
  - `TVMoreActionsButton(viewModel: AssetDetailViewModel, targets: AssetActionTargets, focus: FocusState<String?>.Binding)`.

Behaviour the steps must keep:
- **The button:** `Image(systemName: "ellipsis")`, labelled "More Actions", identifier `A11yID.TV.Detail.more`, focus id `TVDetailFocus.more`. It sits after Favorite in the same `HStack`. While `viewModel.deletingItemIDs` isn't empty, it shows a `ProgressView` in place of the glyph and ignores Select. **It is never `.disabled`**: disabling the focused button would hand focus to tvOS, which would pick something else on the page.
- **The cover** (`fullScreenCover(item:)` on a small `enum TVMoreActionsCover: Identifiable { case actions, playlist(MediaItem), confirmDelete(MediaItem) }`): one state at a time, so the cover never chains two presentations in one pass. Choosing Add to Playlist switches `.actions` → `.playlist(target)`. Choosing Delete switches → `.confirmDelete(target)`, which shows `TVConfirmation` with `deleteActionLabel`, `deleteConfirmationMessage` and the action "Delete". Menu closes the cover onto More.
- **`TVAssetActionsPage`** is laid out like `TVSettingsPicker`: a 900pt column over `.ultraThickMaterial`, titled with `viewModel.seriesItem ?? item`'s name. It has an "Add to Playlist" section, then a "Delete" section only when `targets.deletable` isn't empty, with destructive rows through `TVSettingsRow`'s role. Each section is a container named for its heading, as on Profile (VoiceOver passes over header traits). Default focus is the first row.
- **The delete runs in `TVMoreActionsButton`, in a bare `Task`, after the cover closes** (iOS's rule: the work must outlive the page it may pop). The outcome decides what follows: `.stayAndRefresh` does nothing, `.popOneLevel` calls `tvPopPage`, and `.popToRoot` calls `tvPopToRoot`. A failure raises an `.alert("Couldn't delete")` with OK. `PartialSeasonDeletionError`'s message already says "Deleted N of M".
- **`TVAddToPlaylistPage`** follows `AddToPlaylistSheet` row for row: New Playlist first, then "Your Playlists". Each playlist is a row, disabled and ticked when `alreadyContainsTarget`, with "Already added" as its accessibility value. With no playlists, the sheet's footer text appears. Loading shows `TVDetailLoading`, and failure shows `TVPageMessage` with Try Again. New Playlist goes to a form page within the same cover: a `TextField("Playlist Name")` (tvOS opens its own keyboard), a "Visible to Everyone" on/off `TVSettingsRow` (off by default) with the sheet's footer as its hint, and Create (disabled while the name is blank). Create asks through `TVConfirmation(isDestructive: false)` with `createConfirmationMessage`. Picking a playlist for a show or season asks with `addConfirmationMessage` and `addActionTitle`, and anything else adds at once. On success, post `ToastCenter.shared.post(Toast(message:))` with the view model's toast copy, then close the cover. On failure, show the `.alert("Couldn't add to playlist")` and keep the cover open.

- [ ] **Step 1: Write the failing journeys** in `MoreActionsJourneyTests` (stub server, `launchAtHomeTile`, then navigate to a movie in the fixture library):
  - `test_more_sitsAfterFavorite_andOpensTheActions`: Right from Favorite focuses `tv.detail.more`. Select shows `A11yID.TV.Actions.addToPlaylist(movieID)` and `delete(movieID)`. Menu closes the cover with focus back on More.
  - `test_more_withoutDeletePermission_offersOnlyAddToPlaylist` (`noDeletePermission`): the add row exists and no `delete(_:)` row does.
  - `test_addMovieToPlaylist_addsAtOnce_andCloses`: Select the add row, then a playlist row. The cover closes, and the stub's recorded `POST /Playlists/{id}/Items` carries the movie's id (use the same check `AddToPlaylistJourneyTests` uses).
  - `test_addToPlaylist_alreadyContained_rowIsDisabled`: use the fixture playlist that already holds the item, as in the iOS journey.
  - `test_newPlaylist_createsAfterConfirming`.
  - `test_deleteMovie_confirmFocusesCancel_andMenuCancels`.
  - `test_deleteMovie_popsBackToTheGrid`: after confirming, the detail page is gone and the grid no longer lists the movie (the grid reloads when it comes back on show; the stub drops deleted ids).
- [ ] **Step 2:** Run them (`-only-testing:DionysusTVUITests/MoreActionsJourneyTests`). Expected: FAIL, because `tv.detail.more` isn't found.
- [ ] **Step 3:** Implement the button, the cover and both pages as described, and wire up the movie page. Then `xcodegen generate`.
- [ ] **Step 4:** Screenshot on the tvOS 27 Simulator: More focused, the actions page (with and without Delete), the playlist picker, the new-playlist form and a delete confirmation. Show them to Benjamin and **wait for his go-ahead**.
- [ ] **Step 5:** Run `MoreActionsJourneyTests`. Expected: PASS. Then check focus on the tvOS 26 Simulator by hand: open, close with Menu, and confirm that cancelling a confirmation lands back on More.
- [ ] **Step 6:** Add the actions page and the playlist page to `AccessibilityAuditTests` (open each, `performAccessibilityAudit()` on the structural types) and run the new audits. Expected: PASS.

### Task 5: Show pages (series, season, episode)

**Files:**
- Modify: `DionysusTV/Browse/Detail/TVShowDetailView.swift`
- Test: `DionysusTVUITests/MoreActionsJourneyTests.swift`

**Interfaces:**
- Consumes: `AssetActionTargets(viewModel:selectedSeasonID:)` with `selectedSeasonID: seasonID`, and `TVDetailActions(moreTargets:)`.

Changes, each ported from iOS's `ShowDetailView`:
- `.task(id: [seasonID ?? ""] + viewModel.seasons.map(\.id)) { if let seasonID { await viewModel.loadSeasonDeletability(seasonID: seasonID) } }`.
- `onChange(of: viewModel.seasons.map(\.id))`: when `selectedSeasonID` is no longer listed, set it to `viewModel.preselectedSeasonID ?? ids.first`.
- When the chosen episode is gone (`chosenEpisodeID` not in `loadedEpisodes` after the refresh token bumps), set `chosenEpisodeID = nil`, so the page falls back to the series as iOS's hero does. If focus was on that episode's tile, send it to `TVDetailFocus.more` (set until it holds, as the existing Watched fallback does).

- [ ] **Step 1: Write the failing journeys:**
  - `test_more_onAnEpisode_offersShowSeasonAndEpisode`: rows for the show, the season on show and the episode, under both headings, in that order.
  - `test_more_onTheSeries_offersNoEpisode`.
  - `test_deleteEpisode_pickedInPlace_staysOnTheShow`: open the show, pick an episode from the rail, delete it from More. The page is still the show's (title present) and the episode tile is gone.
  - `test_deleteSeason_movesTheTabsToARemainingSeason`: on a two-season fixture show, delete the season on show. One tab remains, it's selected, and its episodes are listed.
  - `test_addSeasonToPlaylist_asksFirst`: the confirmation shows (`A11yID.TV.Actions.addConfirm`) before anything is posted.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement the changes above.
- [ ] **Step 4:** Screenshot the show page's More row and the three-target actions page, show Benjamin and wait.
- [ ] **Step 5:** Run `MoreActionsJourneyTests`, `ShowDetailJourneyTests` and `DetailJourneyTests` (adding a fourth action changes the row's focus order). Expected: PASS.

### Task 6: Docs, strings, full verification, PR

**Files:**
- Modify: `DionysusTV/CLAUDE.md` ("Detail pages": the More button, the cover and why it isn't a `Menu`, the flat sections, the season-on-show rule, delete outcomes through `tvPopPage`/`tvPopToRoot`, the toast being shared)
- Modify: `CLAUDE.md` (root, "Transient confirmations": `ToastHost` is now hosted by `TVMainView` too. "Playlist editing": the Apple TV adds from More)
- Modify: `TESTING.md` if the new journey class needs to join a TV UI shard or plan
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings`

- [ ] **Step 1:** Update the docs above.
- [ ] **Step 2:** Sync the String Catalog: Xcode build per the `automate-xcstrings-catalog-sync` memory, or hand-insert. Expected: any new keys are present, and none of the reused strings show as stale.
- [ ] **Step 3:** Get Benjamin's sign-off on the diff.
- [ ] **Step 4:** Run the full suites one at a time, never two at once: iOS `UnitTests`, `UITests-Smoke`, `TVUnitTests` and the full TV UI plan. Expected: 0 failures, with counts reported.
- [ ] **Step 5:** Commit and open a PR to `develop` (`--merge`), with a concise body. Restore the Simulators' SavareseHillFlix sign-in and move scratch builds to the Trash.
