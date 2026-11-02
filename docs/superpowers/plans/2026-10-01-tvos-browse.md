# tvOS Browse Implementation Plan (Milestone 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Apple TV app's stopgap browse screens with the prototype's Home, detail pages, collection grid, Search and Profile, so anything in the library is reachable from the remote and plays through a detail page.

**Architecture:**
- Pushed pages (detail pages, See All grids) live on a path in `TVShellNavigation`. The shell draws the root page, the top page and the two pages beneath the top; anything deeper is torn down and rebuilt from its kept view model on the way back.
- Every screen sits on the shared iOS view model for it (`HomeViewModel`, `AssetDetailViewModel`, `CollectionGridViewModel`, `SearchViewModel`, `QuickConnectApprovalViewModel`). TV-only code is views plus small pure types (`TVPageKeepAlive`, `TVHeroPager`, `TVAlphabetIndex`, `TVSearchGrouping`, `TVDetailFormat`), each with unit tests.
- Pages never reach the shell: they open a route, select a library and learn whether they are on show through environment values.

**Tech Stack:** Swift 6, SwiftUI (tvOS 26), UIKit focus system, XcodeGen, XCTest/XCUITest (`XCUIRemote`).

**Spec:** `docs/superpowers/specs/2026-10-01-tvos-browse-design.md`. Parent spec: `docs/superpowers/specs/2026-09-29-tvos-app-design.md`. Prototype: https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL, boards `Home`, `MovieDetail`, `ShowDetail`, `Movies`, `Search`, `Settings`; measurements quoted below come from those boards and `project/tv.css`.

## Global Constraints

- **Deployment target** `tvOS 26.0` for every tvOS target. iOS stays at `18.0`.
- **The iOS app must behave identically.** The iOS `UnitTests` plan and `UITests-Smoke` stay green on every PR. Shared-code changes here are moves and extractions only (the badge rule, three preference keys).
- **`DOWNLOADS` is defined only on `DionysusPlayer` and `DionysusPlayerTests`.** Shared code that names a Downloads type stays inside `#if DOWNLOADS`.
- **Every tile on Home, a grid or Search opens a detail page, never playback.** Exceptions: the hero's Play, a detail page's Play/Resume/Restart, an episode tile on a show page, and a playlist's item rows.
- **Watched is the eye (`eye` / `eye.fill`), never a tick**, on buttons and badges.
- **No More button, no Add to Playlist, no Remove from playlist, no Delete from server, no person page.**
- **Search uses the system `.searchable` keyboard**, not a custom one.
- **Keep-alive cap:** the root page, the top page and the two pages directly beneath the top are built; four live pages at most. A hidden page runs no timer, no ambient animation and starts no image load.
- **Focus rules from M2 still hold:** pages claim focus with `tvClaimsFocus`, never `.defaultFocus`; each page's content sits in `TVPageScaffold`.
- **Dark only.** Decorative images get `.accessibilityHidden(true)`.
- **A11y identifiers:** never select on a label, never put an identifier on a screen-root container. New identifiers go in `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` under `A11yID.TV`.
- **The Xcode project is generated:** edit `project.yml`, run `xcodegen generate`, never commit `.xcodeproj`.
- **Localization:** `Text("…")` literals in views, `String(localized:)` elsewhere. Sync `Localizable.xcstrings` in Xcode (Cmd+B) in the same PR as new strings (memory `automate-xcstrings-catalog-sync`). Server content and "S1:E3"-style labels stay unwrapped.
- **Simulator first.** Ask Benjamin for the Bedroom Apple TV only for the memory check in Task 4.
- **Workflow:** Benjamin signs off every commit and every push. Branch from `develop` in the main checkout, one PR per group below, merged with `--merge` once checks pass. CLAUDE.md and TESTING.md are updated in the commit that changes what they describe. Before sign-off run the suites one after another, never concurrently: tvOS unit, tvOS UI, iOS unit, iOS smoke.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never include a Claude session URL.
- **`Config/Version.xcconfig` and `DionysusPlayer/Shared/AppVersion.swift` stay uncommitted.** Never `git add -A`.

**Test commands** (used throughout):

```bash
# tvOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUnitTests
# tvOS UI
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUITests
# iOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UnitTests
# iOS smoke
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UITests-Smoke
```

One class: append `-only-testing:DionysusTVTests/<Class>` (or `DionysusTVUITests/<Class>`).

**A note on the code below.** It was written against the interfaces as read on 2026-10-01. Where a DTO's memberwise initialiser or a shared view's parameter list differs from what a snippet assumes, follow the code in the repository and keep the snippet's behaviour.

## Delivery order

Six PRs. The spec lists Home before the grid; this plan swaps them, because Home's See All pushes a grid page and the grid has to exist first.

| PR | Branch | Tasks |
|---|---|---|
| 1 | `feature/tvos-detail-path` | 1–4: path and cap, badge rule and tiles, player request and outcome, shell hosting and the movie page |
| 2 | `feature/tvos-detail-shows` | 5–6: show page; box set and playlist pages |
| 3 | `feature/tvos-collection-grid` | 7 |
| 4 | `feature/tvos-home` | 8 |
| 5 | `feature/tvos-search` | 9 |
| 6 | `feature/tvos-profile` | 10 |

## File structure

New TV-only files, under `DionysusTV/`:

| File | Responsibility |
|---|---|
| `Shell/TVPageKeepAlive.swift` | Which path levels are built (pure) |
| `Shell/TVRouteEnvironment.swift` | Environment actions: open a route, select a library, "is this page on show" |
| `Shell/TVPageMessage.swift` | A centred message with one action, for failed and empty pages |
| `Browse/Tiles/TVTileBadges.swift` | Heart, eye and progress bar over artwork |
| `Browse/Tiles/TVPosterTile.swift`, `TVLandscapeTile.swift` | The two tile shapes |
| `Browse/Tiles/TVRail.swift` | A titled horizontal rail |
| `Browse/Detail/TVDetailFormat.swift` | Play-button title, time left, metadata line (pure) |
| `Browse/Detail/TVDetailPage.swift` | Chooses the page for an item's kind; loading and failure |
| `Browse/Detail/TVDetailHeader.swift` | Backdrop, logo, metadata, badges, overview |
| `Browse/Detail/TVDetailActions.swift` | Play/Resume, Restart, Watched, Favorite |
| `Browse/Detail/TVMovieDetailView.swift` | Movie page body |
| `Browse/Detail/TVShowDetailView.swift`, `TVSeasonEpisodesModel.swift` | Show page; one season's episodes |
| `Browse/Detail/TVBoxSetDetailView.swift`, `TVPlaylistDetailView.swift` | Those pages |
| `Browse/TVAlphabetIndex.swift` | Letter for a title, first item per letter (pure) |
| `Browse/TVCollectionGridView.swift` | The grid (replaces `TVLibraryGridView.swift`) |
| `Browse/Home/TVHeroPager.swift` | Hero index and timer rules (pure) |
| `Browse/Home/TVHeroPlayTarget.swift` | Which item the hero's Play starts |
| `Browse/Home/TVHeroView.swift`, `TVHomeView.swift` | Home (replaces `TVBrowseLauncher.swift`) |
| `Browse/TVSearchGrouping.swift` | Results into rails by type (pure) |
| `Shell/Profile/TVSettingsRow.swift` | A focusable settings row |
| `Shell/Profile/TVAdvancedPlaybackView.swift`, `TVQuickConnectApprovalView.swift`, `TVTextPageView.swift` | Profile's sub-screens |

Shared files added or changed: `DionysusPlayer/Core/Models/WatchBadges.swift` (new), `DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift` (new, three keys moved out of iOS-only views), `Shared/Components/PosterCard.swift`, `App/AppState.swift`, `Shared/Accessibility/AccessibilityIdentifiers.swift`.

## Review Focus

Five conditions the spec implies that a person will meet, each pinned by a test in the task named:

1. **A detail page changes an item's Watched or Favorite state, then Menu returns to the tile beneath.** The tile shows the new badge without the page jumping to the top. Task 7, `test_watchedOnDetail_showsOnTheGridTileAfterBack`.
2. **A More Like This chain six deep, then Menu six times.** Every step lands on a page with focus on something, and the last lands on the root tile it started from. Task 4, `test_moreLikeThisChain_pastTheCap_unwindsToTheRootTile`.
3. **A library whose titles don't start with A–Z** (digits, punctuation, accented or non-Latin names, a leading "The"). Each sorts under a letter the bar shows, and no title is unreachable. Task 7, `TVAlphabetIndexTests`.
4. **A show with seasons but no episodes yet, and an empty playlist or box set.** The page shows a message, has no dead Play button, and Menu still works. Task 4, `test_showWithoutEpisodes_hasNoPlayTitle`; Task 5, `test_emptySeason_isLoadedAndEmpty`; Task 6, `test_emptyPlaylist_showsMessage_andMenuPops`.
5. **Menu pressed while a detail page is still loading, or the load fails.** Menu pops; a failure shows Retry with focus on it. Task 4, `test_failedDetail_showsRetry_andMenuPops`.

---

## PR 1 — the path, tiles and the movie page

### Task 1: The path and the keep-alive cap

**Files:**
- Create: `DionysusTV/Shell/TVPageKeepAlive.swift`
- Modify: `DionysusTV/Shell/TVShellNavigation.swift`
- Test: `DionysusTVTests/TVPageKeepAliveTests.swift`, `DionysusTVTests/TVShellNavigationTests.swift`

**Interfaces:**
- Produces:
  - `struct TVPathEntry: Identifiable, Equatable { let id: UUID; let route: AppRoute }`
  - `TVShellNavigation.path: [TVPathEntry]` (read-only), `mutating func push(_ route: AppRoute, id: UUID = UUID()) -> TVPathEntry`, `mutating func pop() -> TVPathEntry?`
  - `TVShellNavigation.select(_:)` clears the path when it navigates.
  - `enum TVPageKeepAlive { static let liveBeneathTop = 2; static func liveLevels(depth: Int) -> Set<Int> }`. Level 0 is the root page; level `n` is `path[n - 1]`; `depth` is `path.count`.

- [ ] **Step 1: Write the failing tests**

`DionysusTVTests/TVPageKeepAliveTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// The root page, the top page and the two beneath the top are built
/// (Benjamin, 2026-10-01): four live pages at most, however deep the path.
final class TVPageKeepAliveTests: XCTestCase {
    func test_rootAlone() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 0), [0])
    }

    func test_upToThreePushed_everythingIsLive() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 1), [0, 1])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 2), [0, 1, 2])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 3), [0, 1, 2, 3])
    }

    func test_deeper_keepsRoot_top_andTwoBeneathIt() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 4), [0, 2, 3, 4])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 10), [0, 8, 9, 10])
    }

    func test_neverMoreThanFourLivePages() {
        for depth in 0...50 {
            XCTAssertLessThanOrEqual(TVPageKeepAlive.liveLevels(depth: depth).count, 4)
        }
    }
}
```

Append to `DionysusTVTests/TVShellNavigationTests.swift`, inside the class:

```swift
    private let movie = AppRoute.assetDetail(itemID: "m1")
    private let other = AppRoute.assetDetail(itemID: "m2")

    func test_push_appendsToThePath_andKeepsTheDestination() {
        var nav = TVShellNavigation()
        _ = nav.select(.library("l1"))
        let entry = nav.push(movie)
        XCTAssertEqual(nav.path, [entry])
        XCTAssertEqual(nav.destination, .library("l1"))
        XCTAssertEqual(nav.railAnchor(libraries: four), .library("l1"), "The rail's anchor is the destination at any depth")
    }

    /// The same title can be on the path twice (A, then B from More Like This,
    /// then A again), so entries are told apart by id, not route.
    func test_theSameRouteTwice_makesTwoEntries() {
        var nav = TVShellNavigation()
        let first = nav.push(movie)
        _ = nav.push(other)
        let again = nav.push(movie)
        XCTAssertNotEqual(first.id, again.id)
        XCTAssertEqual(nav.path.count, 3)
    }

    func test_pop_removesTheTop_andReturnsIt() {
        var nav = TVShellNavigation()
        _ = nav.push(movie)
        let top = nav.push(other)
        XCTAssertEqual(nav.pop(), top)
        XCTAssertEqual(nav.path.count, 1)
    }

    func test_pop_onAnEmptyPath_returnsNil() {
        var nav = TVShellNavigation()
        XCTAssertNil(nav.pop())
    }

    func test_choosingARow_dropsThePath() {
        var nav = TVShellNavigation()
        _ = nav.push(movie)
        _ = nav.select(.search)
        XCTAssertTrue(nav.path.isEmpty)
    }

    func test_togglingTheLibrariesGroup_keepsThePath() {
        var nav = TVShellNavigation()
        _ = nav.push(movie)
        _ = nav.select(.librariesGroup)
        XCTAssertEqual(nav.path.count, 1)
    }
```

- [ ] **Step 2: Run them and see them fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVPageKeepAliveTests -only-testing:DionysusTVTests/TVShellNavigationTests` (after `xcodegen generate`).
Expected: build fails, "cannot find 'TVPageKeepAlive' in scope" and "value of type 'TVShellNavigation' has no member 'push'".

- [ ] **Step 3: Implement**

`DionysusTV/Shell/TVPageKeepAlive.swift`:

```swift
import Foundation

/// Which pages of the shell's stack are built (Benjamin, 2026-10-01). Level 0
/// is the root page (Home, Search, a library, Profile); level `n` is the
/// path's `n`th entry. The root, the top and the two beneath the top stay
/// alive, so Menu returns to a page exactly as it was; anything deeper is
/// torn down and rebuilt from its kept view model on the way back.
///
/// The cost of a live page is memory (its decoded images), not frame time: a
/// hidden page isn't drawn. The cap bounds that at four pages.
enum TVPageKeepAlive {
    static let liveBeneathTop = 2

    static func liveLevels(depth: Int) -> Set<Int> {
        let top = max(0, depth)
        return Set([0] + Array(max(0, top - liveBeneathTop)...top))
    }
}
```

In `DionysusTV/Shell/TVShellNavigation.swift`, add above the struct:

```swift
/// One pushed page. The id tells two visits to the same route apart, and
/// keys the page's view model and remembered focus in the shell.
struct TVPathEntry: Identifiable, Equatable {
    let id: UUID
    let route: AppRoute
}
```

Inside `TVShellNavigation`, add the stored property after `destination`:

```swift
    /// Pages pushed on top of the destination: detail pages and See All
    /// grids. Menu pops it before it opens the rail.
    private(set) var path: [TVPathEntry] = []
```

Replace `select(_:)` with:

```swift
    mutating func select(_ row: Row) -> Selection {
        if row == .librariesGroup {
            librariesExpanded.toggle()
            return .toggledGroup
        }
        destination = row
        path = []
        return .navigated
    }

    @discardableResult
    mutating func push(_ route: AppRoute, id: UUID = UUID()) -> TVPathEntry {
        let entry = TVPathEntry(id: id, route: route)
        path.append(entry)
        return entry
    }

    mutating func pop() -> TVPathEntry? {
        path.popLast()
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: the same command. Expected: PASS.

- [ ] **Step 5: Commit** (after Benjamin's sign-off)

```bash
git add DionysusTV/Shell/TVPageKeepAlive.swift DionysusTV/Shell/TVShellNavigation.swift DionysusTVTests/TVPageKeepAliveTests.swift DionysusTVTests/TVShellNavigationTests.swift
git commit -m "Add a path to the Apple TV shell, with a cap on live pages"
```

### Task 2: The shared badge rule and the TV tiles

**Files:**
- Create: `DionysusPlayer/Core/Models/WatchBadges.swift`, `DionysusTV/Browse/Tiles/TVTileBadges.swift`, `DionysusTV/Browse/Tiles/TVPosterTile.swift`, `DionysusTV/Browse/Tiles/TVLandscapeTile.swift`, `DionysusTV/Browse/Tiles/TVRail.swift`
- Modify: `DionysusPlayer/Shared/Components/PosterCard.swift` (`watchStatusOverlay(for:)`)
- Test: `DionysusPlayerTests/Core/Models/WatchBadgesTests.swift` (compiled into both unit-test targets by the existing `Core/Models/**` include)

**Interfaces:**
- Produces:
  - `struct WatchBadges: Equatable { let showsFavorite: Bool; let showsWatched: Bool; let progress: Double?; init(isFavorite: Bool, isPlayed: Bool, playedFraction: Double?); init(item: MediaItem) }`
  - `enum TVTileMetrics { static let poster = CGSize(width: 250, height: 375); static let gridPoster = CGSize(width: 240, height: 360); static let landscape = CGSize(width: 500, height: 281); static let episode = CGSize(width: 440, height: 248) }`
  - `enum TVTileCaption { case always, onFocus, none }`
  - `TVPosterTile(item: MediaItem, size: CGSize = TVTileMetrics.poster, caption: TVTileCaption = .onFocus, identifier: String, action: @escaping () -> Void)`
  - `TVLandscapeTile(item: MediaItem, size: CGSize = TVTileMetrics.landscape, title: String, subtitle: String?, identifier: String, action: @escaping () -> Void)`
  - `TVRail(title: String, titleIdentifier: String? = nil) { content }`

- [ ] **Step 1: Write the failing test**

`DionysusPlayerTests/Core/Models/WatchBadgesTests.swift`:

```swift
import XCTest
#if os(tvOS)
@testable import Dionysus
#else
@testable import DionysusPlayer
#endif

/// Which corner badges a tile shows: one rule for iOS's `PosterCard` and the
/// Apple TV tiles.
final class WatchBadgesTests: XCTestCase {
    func test_untouchedItem_showsNothing() {
        let badges = WatchBadges(isFavorite: false, isPlayed: false, playedFraction: nil)
        XCTAssertEqual(badges, WatchBadges(isFavorite: false, isPlayed: false, playedFraction: 0))
        XCTAssertFalse(badges.showsFavorite)
        XCTAssertFalse(badges.showsWatched)
        XCTAssertNil(badges.progress)
    }

    func test_partWatched_showsProgressOnly() {
        let badges = WatchBadges(isFavorite: false, isPlayed: false, playedFraction: 0.4)
        XCTAssertEqual(badges.progress, 0.4)
        XCTAssertFalse(badges.showsWatched)
    }

    /// A played item can still carry a resume position; the bar is only for
    /// something part-watched.
    func test_played_showsTheEye_andNoProgress() {
        let badges = WatchBadges(isFavorite: false, isPlayed: true, playedFraction: 0.9)
        XCTAssertTrue(badges.showsWatched)
        XCTAssertNil(badges.progress)
    }

    func test_favoriteAndWatched_showTogether() {
        let badges = WatchBadges(isFavorite: true, isPlayed: true, playedFraction: nil)
        XCTAssertTrue(badges.showsFavorite)
        XCTAssertTrue(badges.showsWatched)
    }
}
```

Check the module name the other shared tests import (`head -5 DionysusPlayerTests/Core/Models/MediaItemTests.swift`) and use the same import lines.

- [ ] **Step 2: Run it and see it fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/WatchBadgesTests`. Expected: build fails, "cannot find 'WatchBadges' in scope".

- [ ] **Step 3: Implement the rule and use it on iOS**

`DionysusPlayer/Core/Models/WatchBadges.swift`:

```swift
import Foundation

/// Which corner badges a tile shows, on iOS and the Apple TV alike: a heart
/// for a favourite, an eye for a played item, and a progress bar only while
/// the item is part-watched. The heart and the eye can show together.
struct WatchBadges: Equatable {
    let showsFavorite: Bool
    let showsWatched: Bool
    /// The played fraction, `nil` unless the item is part-watched.
    let progress: Double?

    init(isFavorite: Bool, isPlayed: Bool, playedFraction: Double?) {
        showsFavorite = isFavorite
        showsWatched = isPlayed
        if let playedFraction, playedFraction > 0, !isPlayed {
            progress = playedFraction
        } else {
            progress = nil
        }
    }

    init(item: MediaItem) {
        self.init(isFavorite: item.isFavorite, isPlayed: item.isPlayed, playedFraction: item.playedFraction)
    }
}
```

In `DionysusPlayer/Shared/Components/PosterCard.swift`, `watchStatusOverlay(for:)`: add `let badges = WatchBadges(item: item)` as its first line (make the body an explicit `return`), and replace the three conditions, keeping every comment and every view as it is:
- `if let fraction = item.playedFraction, fraction > 0, !item.isPlayed {` → `if let fraction = badges.progress {`
- `if item.isFavorite {` → `if badges.showsFavorite {`
- `if item.isPlayed {` → `if badges.showsWatched {`

- [ ] **Step 4: Run the test on both platforms**

Run: tvOS unit and iOS unit, each with `-only-testing:<target>/WatchBadgesTests`. Expected: PASS on both.

- [ ] **Step 5: Write the TV tiles**

`DionysusTV/Browse/Tiles/TVTileBadges.swift`:

```swift
import SwiftUI

/// Tile sizes from the prototype's `tv.css` (`.poster`, `.poster-s`, `.land`,
/// `.land-s`).
enum TVTileMetrics {
    static let poster = CGSize(width: 250, height: 375)
    /// Six to a row in a collection grid.
    static let gridPoster = CGSize(width: 240, height: 360)
    static let landscape = CGSize(width: 500, height: 281)
    static let episode = CGSize(width: 440, height: 248)
}

enum TVTileCaption {
    case always
    /// Posters on Home and in grids: the caption appears under the focused
    /// tile only, as the prototype's `hide-cap`.
    case onFocus
    case none
}

/// iOS's corner badges over a tile's artwork: a heart top-left, an eye
/// top-right, a progress bar along the bottom while part-watched. Never a
/// tick for watched.
struct TVTileBadges: View {
    let badges: WatchBadges

    var body: some View {
        ZStack {
            if badges.showsFavorite {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(Color.white, Color.dionysusFavorite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if badges.showsWatched {
                Image(systemName: "eye.circle.fill")
                    .foregroundStyle(Color.white, Color.dionysusWatched)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let progress = badges.progress {
                ProgressView(value: progress)
                    .tint(.dionysusHighlight)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .font(.system(size: 34))
        .padding(12)
        .accessibilityHidden(true)
    }
}
```

`DionysusTV/Browse/Tiles/TVPosterTile.swift`:

```swift
import SwiftUI

/// A portrait tile: artwork in a card button, badges over it, and a caption
/// beneath. Selecting one always opens something (a detail page, a grid),
/// never playback.
struct TVPosterTile: View {
    let item: MediaItem
    var size: CGSize = TVTileMetrics.poster
    var caption: TVTileCaption = .onFocus
    let identifier: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: action) {
                AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                    .frame(width: size.width, height: size.height)
                    .overlay { TVTileBadges(badges: WatchBadges(item: item)) }
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityIdentifier(identifier)

            if caption != .none {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.railTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    if let subtitle = item.railSubtitle {
                        Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: size.width, alignment: .leading)
                .opacity(caption == .always || isFocused ? 1 : 0)
                .accessibilityHidden(true)
            }
        }
    }
}
```

`DionysusTV/Browse/Tiles/TVLandscapeTile.swift`:

```swift
import SwiftUI

/// A 16:9 tile with its caption always shown: Continue Watching, Next Up,
/// episodes and playlist rows. The caller supplies the caption, since an
/// episode reads differently on Home ("Pioneer One" / "S1:E3 · Alone in the
/// Night") and on its show's page ("3. Alone in the Night" / "S1:E3 · 31 min").
struct TVLandscapeTile: View {
    let item: MediaItem
    var size: CGSize = TVTileMetrics.landscape
    let title: String
    let subtitle: String?
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: action) {
                AsyncRemoteImage(
                    url: item.thumbImageURL ?? item.primaryImageURL,
                    placeholderSystemImage: item.kind.placeholderSystemImage
                )
                .frame(width: size.width, height: size.height)
                .overlay { TVTileBadges(badges: WatchBadges(item: item)) }
            }
            .buttonStyle(.card)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityIdentifier(identifier)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }
}
```

`DionysusTV/Browse/Tiles/TVRail.swift`:

```swift
import SwiftUI

/// A titled horizontal rail. The row is a focus section, so Down from
/// anything above lands in it even where no tile sits directly below.
struct TVRail<Content: View>: View {
    let title: String
    var titleIdentifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? "")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content }
                    .padding(.vertical, 30)
                    .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}
```

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild build -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0'`. Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit** (after sign-off)

```bash
git add DionysusPlayer/Core/Models/WatchBadges.swift DionysusPlayer/Shared/Components/PosterCard.swift DionysusPlayerTests/Core/Models/WatchBadgesTests.swift DionysusTV/Browse/Tiles
git commit -m "Share the tile badge rule and add the Apple TV tiles"
```

### Task 3: The player takes a request and reports where it stopped

**Files:**
- Modify: `DionysusTV/Player/TVPlaybackSession.swift`, `DionysusTV/Player/TVPlayerHostController.swift`, `DionysusTV/Player/TVPlayerPresenter.swift`
- Test: `DionysusTVTests/TVPlaybackSessionTests.swift`

**Interfaces:**
- Consumes: `PlaybackRequest` (`itemID`, `startFromBeginning`, `mediaSourceID`), `PlaybackSessionOutcome`, `RecentPlaybackBroadcaster.shared.record(_:)`, `PlayerViewModel.init(client:userID:itemID:engine:startFromBeginning:mediaSourceID:…playbackQueue:)`.
- Produces:
  - `TVPlaybackSession.end() -> PlaybackSessionOutcome?` (`@discardableResult`; `nil` on every call after the first).
  - `TVPlayerPresenter.present(_ request: PlaybackRequest, queue: [MediaItem] = [], client: JellyfinAPIClient, userID: String, onClose: (@MainActor (PlaybackSessionOutcome) -> Void)? = nil)`
  - `TVPlayerPresenter.present(itemID:client:userID:)` stays as a wrapper until Task 9 removes its last caller. `present(item:client:userID:)` is deleted.

- [ ] **Step 1: Write the failing test**

Append to `TVPlaybackSessionTests`, reusing the file's existing way of building a `PlayerViewModel` (extract its construction into a `private func makeViewModel() throws -> PlayerViewModel` helper with the same arguments the first test uses, and call it from both):

```swift
    /// The presenter learns where playback stopped from the session, once:
    /// Menu can call `end()` twice (during presentation, then again from
    /// `viewDidAppear`), and the page beneath must not be told twice.
    func test_end_reportsTheOutcomeOnce() async throws {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }
        let session = TVPlaybackSession(viewModel: try makeViewModel())

        let first = session.end()
        XCTAssertEqual(first?.itemID, "item-1")
        XCTAssertNil(session.end(), "A second end reports nothing")
    }
```

- [ ] **Step 2: Run it and see it fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVPlaybackSessionTests`. Expected: build fails, "cannot convert value of type '()' to …" on `let first = session.end()`.

- [ ] **Step 3: Implement**

In `TVPlaybackSession.swift`, replace `end()`:

```swift
    /// Safe in any state, `.loading` included. Returns where playback
    /// stopped, the first time only: read before `stop()`, which reports the
    /// same position to the server.
    @discardableResult
    func end() -> PlaybackSessionOutcome? {
        guard !hasEnded else { return nil }
        hasEnded = true
        startTask?.cancel()
        let outcome = PlaybackSessionOutcome(
            itemID: viewModel.itemID, positionSeconds: viewModel.currentTime, durationSeconds: viewModel.duration
        )
        Task { [viewModel] in await viewModel.stop() }
        return outcome
    }
```

In `TVPlayerHostController.swift`, add a property and replace `close()`:

```swift
    /// Told where playback stopped, after the player has gone, so the page
    /// beneath can show it at once instead of waiting on the server.
    var onClose: (@MainActor (PlaybackSessionOutcome) -> Void)?
    private var pendingOutcome: PlaybackSessionOutcome?

    /// Ends the session before dismissing, in any state, `.loading` included.
    /// UIKit ignores a dismiss while the presentation is still animating, so
    /// one pressed then is left to `viewDidAppear`.
    func close() {
        if let outcome = session.end() {
            pendingOutcome = outcome
            // As iOS's `PlayerView` does: Home has no other way to learn it.
            RecentPlaybackBroadcaster.shared.record(outcome)
        }
        guard !isBeingPresented else { return }
        dismiss(animated: true) { [onClose, pendingOutcome] in
            if let pendingOutcome { onClose?(pendingOutcome) }
        }
    }
```

In `TVPlayerPresenter.swift`, replace both `present` functions:

```swift
    /// `request.itemID` must be directly playable: a movie or an episode.
    /// `queue` is the playlist being played through, empty otherwise.
    @MainActor
    static func present(
        _ request: PlaybackRequest,
        queue: [MediaItem] = [],
        client: JellyfinAPIClient,
        userID: String,
        onClose: (@MainActor (PlaybackSessionOutcome) -> Void)? = nil
    ) {
        guard let engine = makeEngine() else { return }
        let viewModel = PlayerViewModel(
            client: client, userID: userID, itemID: request.itemID, engine: engine,
            startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
            playbackQueue: queue
        )
        let host = TVPlayerHostController(viewModel: viewModel, engine: engine)
        host.onClose = onClose
        host.modalPresentationStyle = .fullScreen
        guard let presenter = topViewController() else { return }
        presenter.present(host, animated: true)
    }

    @MainActor
    static func present(itemID: String, client: JellyfinAPIClient, userID: String) {
        present(PlaybackRequest(itemID: itemID), client: client, userID: userID)
    }
```

Change the two `TVPlayerPresenter.present(item: item, …)` call sites (`TVBrowseLauncher`, `TVLibraryGridView`) to `present(itemID: item.id, …)`.

- [ ] **Step 4: Run the tests**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVPlaybackSessionTests`, then tvOS UI with `-only-testing:DionysusTVUITests/PlayerJourneyTests`. Expected: PASS.

- [ ] **Step 5: Commit** (after sign-off)

```bash
git add DionysusTV/Player DionysusTV/Browse/TVBrowseLauncher.swift DionysusTV/Browse/TVLibraryGridView.swift DionysusTVTests/TVPlaybackSessionTests.swift
git commit -m "Let the Apple TV player take a request and report where it stopped"
```

### Task 4: The shell hosts the path, and the movie page

**Files:**
- Create: `DionysusTV/Shell/TVRouteEnvironment.swift`, `DionysusTV/Shell/TVPageMessage.swift`, `DionysusTV/Browse/Detail/TVDetailFormat.swift`, `TVDetailPage.swift`, `TVDetailHeader.swift`, `TVDetailActions.swift`, `TVMovieDetailView.swift`
- Modify: `DionysusTV/Browse/TVMainView.swift`, `DionysusTV/Shell/TVDefaultFocus.swift`, `DionysusTV/Browse/TVBrowseLauncher.swift`, `TVLibraryGridView.swift`, `TVSearchView.swift`, `AccessibilityIdentifiers.swift`, `DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift` (a `failingDetail` scenario)
- Test: `DionysusTVTests/TVDetailFormatTests.swift`, `DionysusTVUITests/DetailJourneyTests.swift`, `DionysusTVUITests/Support/TVShellJourney.swift`, and the M2 journeys that select a tile
- Docs: `CLAUDE.md`, `TESTING.md`

**Interfaces:**
- Consumes: Task 1 (`push`, `pop`, `TVPageKeepAlive`), Task 2 (tiles, rail), Task 3 (`present(_:queue:client:userID:onClose:)`).
- Produces:
  - Environment: `tvOpenRoute: @MainActor (AppRoute) -> Void`, `tvSelectLibrary: @MainActor (String) -> Void`, `tvPageIsOnShow: Bool`.
  - `TVPageMessage(title: String, message: String?, actionTitle: LocalizedStringKey, actionIdentifier: String, action: @escaping () -> Void)`; it focuses its button itself.
  - `TVDetailPage(viewModel: AssetDetailViewModel, client: JellyfinAPIClient, userID: String, rememberedFocus: Binding<String?>)`
  - `TVDetailHeader(item: MediaItem, showsBadges: Bool)`, `TVDetailBackdrop(item: MediaItem)`
  - `TVDetailActions(viewModel: AssetDetailViewModel, playTarget: MediaItem?, statusTarget: MediaItem, isShow: Bool, focus: FocusState<String?>.Binding, play: @escaping (PlaybackRequest) -> Void)`; its focus ids are `TVDetailFocus.play`, `.restart`, `.watched`, `.favorite` (Strings).
  - `enum TVDetailFormat { static func playTitle(target: MediaItem?, isShow: Bool) -> String?; static func timeLeft(runTimeTicks: Int64?, resumeSeconds: Double?) -> String?; static func metadata(for item: MediaItem) -> [String] }`
  - `A11yID.TV.Detail`: `play`, `restart`, `watched`, `favorite`, `overview`, `title`, `retry`, `similar(_:)`.

- [ ] **Step 1: Write the failing unit tests**

`DionysusTVTests/TVDetailFormatTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVDetailFormatTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func item(_ dto: BaseItemDto) -> MediaItem { MediaItem(dto: dto, images: images) }

    func test_timeLeft_roundsUpToWholeMinutes() {
        // 95 minutes long, 48 minutes in: 47 left.
        XCTAssertEqual(TVDetailFormat.timeLeft(runTimeTicks: 95 * 600_000_000, resumeSeconds: 48 * 60), "47 min left")
        // 30 seconds left still reads as a minute, never "0 min left".
        XCTAssertEqual(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 30), "1 min left")
    }

    func test_timeLeft_isNilWithoutAResumePoint_orARuntime() {
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: nil))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 0))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: nil, resumeSeconds: 30))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 0, resumeSeconds: 30))
    }

    /// A position past the end (a stale resume point on a re-encoded file)
    /// must not read as a negative time.
    func test_timeLeft_isNilWhenThePositionIsPastTheEnd() {
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 120))
    }

    func test_playTitle_forAMovie() {
        let fresh = item(BaseItemDto(id: "m", name: "Arrival", type: .movie))
        XCTAssertEqual(TVDetailFormat.playTitle(target: fresh, isShow: false), "Play")
        var dto = BaseItemDto(id: "m", name: "Arrival", type: .movie)
        dto.runTimeTicks = 95 * 600_000_000
        var userData = UserItemDataDto()
        userData.playbackPositionTicks = 48 * 600_000_000
        dto.userData = userData
        XCTAssertEqual(TVDetailFormat.playTitle(target: item(dto), isShow: false), "Resume")
    }

    func test_playTitle_forAShow_namesTheEpisode() {
        var dto = BaseItemDto(id: "e", name: "Alone in the Night", type: .episode)
        dto.parentIndexNumber = 1
        dto.indexNumber = 3
        XCTAssertEqual(TVDetailFormat.playTitle(target: item(dto), isShow: true), "Play S1:E3")
    }

    /// Review Focus 4: a show with seasons and no episodes has nothing to
    /// play, so there is no title and the page draws no Play button.
    func test_showWithoutEpisodes_hasNoPlayTitle() {
        XCTAssertNil(TVDetailFormat.playTitle(target: nil, isShow: true))
    }

    func test_metadata_skipsWhatTheItemLacks() {
        var dto = BaseItemDto(id: "m", name: "Arrival", type: .movie)
        dto.officialRating = "PG-13"
        dto.genres = ["Sci-Fi", "Drama", "Mystery"]
        // No year and no runtime: neither leaves a gap or a stray separator.
        XCTAssertEqual(TVDetailFormat.metadata(for: item(dto)), ["PG-13", "Sci-Fi, Drama"])
    }
}
```

- [ ] **Step 2: Run it and see it fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVDetailFormatTests`. Expected: build fails, "cannot find 'TVDetailFormat' in scope".

- [ ] **Step 3: Implement `TVDetailFormat`**

`DionysusTV/Browse/Detail/TVDetailFormat.swift`:

```swift
import Foundation

/// The detail pages' derived text, kept out of the views so it can be tested.
enum TVDetailFormat {
    /// "Play" or "Resume", with the episode for a show ("Resume S1:E3").
    /// `nil` when there is nothing to play: a show whose seasons hold no
    /// episodes yet, where the page draws no Play button at all.
    static func playTitle(target: MediaItem?, isShow: Bool) -> String? {
        guard let target else { return nil }
        let verb = (target.resumePositionSeconds ?? 0) > 0 && !target.isPlayed
            ? String(localized: "Resume") : String(localized: "Play")
        // "S1:E3" is a formatted label, not translated (see `MediaItem.episodeLabel`).
        if isShow, let label = target.episodeLabel { return "\(verb) \(label)" }
        return verb
    }

    /// "47 min left", rounded up so the last seconds never read as zero.
    static func timeLeft(runTimeTicks: Int64?, resumeSeconds: Double?) -> String? {
        guard let runTimeTicks, runTimeTicks > 0, let resumeSeconds, resumeSeconds > 0 else { return nil }
        let remaining = Double(runTimeTicks) / 10_000_000 - resumeSeconds
        guard remaining > 0 else { return nil }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(localized: "\(minutes) min left")
    }

    /// Year, age rating, runtime and the first two genres, each only when
    /// the item has it.
    static func metadata(for item: MediaItem) -> [String] {
        let genres = item.genres.prefix(2).joined(separator: ", ")
        return [item.yearText, item.ageRating, item.durationText, genres.isEmpty ? nil : genres].compactMap { $0 }
    }
}
```

Run the unit tests again. Expected: PASS. If `BaseItemDto`'s field names differ (`officialRating`, `parentIndexNumber`, `playbackPositionTicks`), fix the test to the DTO.

- [ ] **Step 4: Add the environment values, identifiers and the message view**

`DionysusTV/Shell/TVRouteEnvironment.swift`:

```swift
import SwiftUI

extension EnvironmentValues {
    /// Pushes a detail page or a See All grid onto the shell's path.
    @Entry var tvOpenRoute: @MainActor (AppRoute) -> Void = { _ in }

    /// Switches the shell to a library's own page (Home's Libraries rail).
    /// It doesn't push: a library is a top-level page with its own rail row.
    @Entry var tvSelectLibrary: @MainActor (String) -> Void = { _ in }

    /// False for a page kept alive beneath the top one. A hidden page claims
    /// no focus and runs no timer; when it turns true again the page takes
    /// focus back and refreshes what may have changed above it.
    @Entry var tvPageIsOnShow = true
}
```

In `AccessibilityIdentifiers.swift`, inside `enum TV`, add:

```swift
        enum Detail {
            static let title = "tv.detail.title"
            static let play = "tv.detail.play"
            static let restart = "tv.detail.restart"
            static let watched = "tv.detail.watched"
            static let favorite = "tv.detail.favorite"
            static let overview = "tv.detail.overview"
            static let retry = "tv.detail.retry"
            static func similar(_ itemID: String) -> String { "tv.detail.similar.\(itemID)" }
        }
```

`DionysusTV/Shell/TVPageMessage.swift`:

```swift
import SwiftUI

/// A page with nothing to show but a reason and one way forward: a load that
/// failed (Retry), a grid filtered to nothing (Reset Filters). Its button
/// takes focus, so Menu and the rail still work: with focus nowhere, tvOS
/// delivers Menu to nothing.
struct TVPageMessage: View {
    let title: String
    var message: String?
    let actionTitle: LocalizedStringKey
    let actionIdentifier: String
    let action: () -> Void
    @FocusState private var focused: String?
    @State private var remembered: String?

    var body: some View {
        VStack(spacing: 30) {
            Text(verbatim: title).font(.title2.bold())
            if let message {
                Text(verbatim: message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            }
            Button(action: action) { Text(actionTitle).frame(width: 400) }
                .focused($focused, equals: actionIdentifier)
                .accessibilityIdentifier(actionIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, TVShellMetrics.contentInset)
        .tvClaimsFocus($focused, ids: [actionIdentifier], remembered: $remembered)
    }
}
```

- [ ] **Step 5: Make `tvClaimsFocus` aware of hidden pages**

In `DionysusTV/Shell/TVDefaultFocus.swift`, add `@Environment(\.tvPageIsOnShow) private var isOnShow` to `TVDefaultFocus`, and change `body`:

```swift
    func body(content: Content) -> some View {
        content
            .onChange(of: ids.first, initial: true) { _, first in
                guard isOnShow, focus.wrappedValue == nil, let first else { return }
                if let remembered, ids.contains(remembered) {
                    claim(remembered)
                } else if !userMoved, !sidebarExpanded {
                    claim(first)
                }
            }
            .onChange(of: handoff) {
                guard isOnShow, let first = ids.first else { return }
                claim(first)
            }
            // Back on show after the page above was popped: focus returns to
            // where it was. The page was never torn down, so the item is
            // built, lazy container or not.
            .onChange(of: isOnShow) { _, onShow in
                guard onShow else { return }
                if let remembered, ids.contains(remembered) {
                    claim(remembered)
                } else if let first = ids.first {
                    claim(first)
                }
            }
            .onChange(of: focus.wrappedValue) { _, id in
                if let id, isOnShow { remembered = id }
            }
            .onMoveCommand { _ in userMoved = true }
    }
```

Update the doc comment's list with a third bullet: "When the page comes back on show after the page above it is popped: the remembered item."

- [ ] **Step 6: Host the path in the shell**

In `DionysusTV/Browse/TVMainView.swift`:

Add state beside `libraryGrids`:

```swift
    /// One view model per pushed page, keyed by its path entry, kept while
    /// the entry is on the path: a page torn down by the keep-alive cap
    /// rebuilds from it without a refetch.
    @State private var detailModels: [UUID: AssetDetailViewModel] = [:]
    @State private var pushedGrids: [UUID: CollectionGridViewModel] = [:]
    @State private var rememberedPushedFocus: [UUID: String] = [:]
```

Replace the `page … .transition(…)` block in `body` with `pages`, and add the environment actions beside the existing three:

```swift
            pages
```

```swift
        .environment(\.tvOpenRoute, open)
        .environment(\.tvSelectLibrary) { id in select(.library(id)) }
```

Add:

```swift
    /// The root page and the pushed pages the cap keeps alive
    /// (`TVPageKeepAlive`). Only the top one is on show; the rest are built
    /// but hidden and disabled, so Menu returns to them as they were.
    private var pages: some View {
        let live = TVPageKeepAlive.liveLevels(depth: nav.path.count)
        return ZStack {
            level(0) { page }
                .id(nav.destination)
                // Removed at once: a page fading out could still take focus.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            ForEach(Array(nav.path.enumerated()), id: \.element.id) { index, entry in
                if live.contains(index + 1) {
                    level(index + 1) { pushedPage(entry) }
                }
            }
        }
    }

    private func level<Page: View>(_ level: Int, @ViewBuilder _ page: () -> Page) -> some View {
        let onShow = level == nav.path.count
        return page()
            .environment(\.tvPageIsOnShow, onShow)
            .opacity(onShow ? 1 : 0)
            .disabled(!onShow)
            .accessibilityHidden(!onShow)
    }

    @ViewBuilder
    private func pushedPage(_ entry: TVPathEntry) -> some View {
        let focus = Binding(
            get: { rememberedPushedFocus[entry.id] },
            set: { rememberedPushedFocus[entry.id] = $0 }
        )
        switch entry.route {
        case .assetDetail:
            if let model = detailModels[entry.id] {
                TVDetailPage(viewModel: model, client: client, userID: userID, rememberedFocus: focus)
            }
        case .collection(let query):
            if let grid = pushedGrids[entry.id] {
                // Task 7 replaces this stopgap with `TVCollectionGridView`.
                TVLibraryGridView(title: query.title, titleIdentifier: A11yID.TV.Library.title(query.title), viewModel: grid, rememberedItemID: focus)
            }
        default:
            // The downloaded routes don't exist on tvOS.
            EmptyView()
        }
    }

    private func open(_ route: AppRoute) {
        let entry = nav.push(route)
        switch route {
        case .assetDetail(let itemID, let preloadedItem):
            detailModels[entry.id] = AssetDetailViewModel(client: client, userID: userID, itemID: itemID, preloadedItem: preloadedItem)
        case .collection(let query):
            pushedGrids[entry.id] = CollectionGridViewModel(client: client, userID: userID, query: query)
        default:
            break
        }
        // The tile that was focused is now disabled; without the hold, tvOS
        // moves focus to the rail, the only thing left, and opens it.
        holdRail()
    }

    private func pop() {
        guard let entry = nav.pop() else { return }
        detailModels[entry.id]?.cancelBackgroundWork()
        detailModels[entry.id] = nil
        pushedGrids[entry.id] = nil
        rememberedPushedFocus[entry.id] = nil
        holdRail()
    }
```

Replace `exitCommand`:

```swift
    /// Menu: pops a pushed page; on a root page, opens the sidebar on that
    /// page's row; with the sidebar open, nothing, so tvOS leaves the app.
    private var exitCommand: (() -> Void)? {
        if isExpanded { return nil }
        if !nav.path.isEmpty { return pop }
        return {
            railHeld = false
            Task { @MainActor in
                await Task.yield()
                focusedRow = nav.railAnchor(libraries: libraries)
            }
        }
    }
```

In `select(_:)`, before `let selection = …`, drop the pushed pages' state when the row navigates:

```swift
        if row != .librariesGroup {
            detailModels.values.forEach { $0.cancelBackgroundWork() }
            detailModels = [:]
            pushedGrids = [:]
            rememberedPushedFocus = [:]
        }
```

Change `TVLibraryGridView` to take `title: String` and `titleIdentifier: String` instead of `library: MediaItem`, `client` and `userID` (update the root call site to pass `library.name` and `A11yID.TV.Library.title(library.id)`), and make its tiles open detail pages: add `@Environment(\.tvOpenRoute) private var open`, delete `playableKinds`, and replace the button's action with `open(.assetDetail(itemID: item.id, preloadedItem: item))`. Do the same in `TVBrowseLauncher`'s tile action and in `TVSearchView` (`open(.assetDetail(itemID: result.id))`, list every result instead of `playableResults`, and delete `playableKinds`). Update the three doc comments: tiles open detail pages.

- [ ] **Step 7: Write the detail page and the movie page**

`DionysusTV/Browse/Detail/TVDetailPage.swift`:

```swift
import SwiftUI

/// A detail page inside the shell, with the rail beside it: chooses the page
/// for the item's kind and owns loading and failure. Its data is the shared
/// `AssetDetailViewModel`, which the shell keeps for as long as the page is
/// on the path.
struct TVDetailPage: View {
    let viewModel: AssetDetailViewModel
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @Environment(\.tvPageIsOnShow) private var isOnShow

    var body: some View {
        TVPageScaffold(background: { background }) {
            content
        }
        .task { await viewModel.loadIfNeeded() }
        // Back on show: a page above may have changed what this one shows
        // (a watched state, a resume point).
        .onChange(of: isOnShow) { _, onShow in
            if onShow { Task { await viewModel.refreshItem() } }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let item = viewModel.item { TVDetailBackdrop(item: item) }
    }

    @ViewBuilder
    private var content: some View {
        if let item = viewModel.item {
            switch item.kind {
            case .series, .season, .episode:
                // Task 5 replaces this with `TVShowDetailView`.
                TVMovieDetailView(viewModel: viewModel, item: item, client: client, userID: userID, rememberedFocus: $rememberedFocus)
            default:
                TVMovieDetailView(viewModel: viewModel, item: item, client: client, userID: userID, rememberedFocus: $rememberedFocus)
            }
        } else if case .failed(let message) = viewModel.loadState {
            TVPageMessage(
                title: String(localized: "Couldn't Load This Title"), message: message,
                actionTitle: "Try Again", actionIdentifier: A11yID.TV.Detail.retry
            ) { Task { await viewModel.load() } }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

`DionysusTV/Browse/Detail/TVDetailHeader.swift`:

```swift
import SwiftUI

/// The item's backdrop behind the whole page, the rail included, under the
/// prototype's two scrims: dark from the left for the text, and dark from
/// the bottom for the rails.
struct TVDetailBackdrop: View {
    let item: MediaItem
    private static let ground = Color(red: 11 / 255, green: 2 / 255, blue: 8 / 255)

    var body: some View {
        ZStack {
            Self.ground
            AsyncRemoteImage(url: item.backdropImageURL, placeholderSystemImage: item.kind.placeholderSystemImage, retryPatience: .extended)
            LinearGradient(colors: [Self.ground.opacity(0.92), Self.ground.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
            LinearGradient(stops: [.init(color: Self.ground, location: 0), .init(color: Self.ground.opacity(0.75), location: 0.3), .init(color: Self.ground.opacity(0), location: 0.6)], startPoint: .bottom, endPoint: .top)
        }
        .accessibilityHidden(true)
    }
}

/// Logo (title text until it loads, or when there is none), the metadata
/// line, the format badges and nothing else: the overview and the actions
/// are focusable, so the page lays those out itself.
struct TVDetailHeader: View {
    let item: MediaItem
    var showsBadges = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            logo
                .frame(width: 640, height: 210, alignment: .bottomLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Detail.title)
            HStack(spacing: 16) {
                ForEach(Array(TVDetailFormat.metadata(for: item).enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true) }
                    Text(verbatim: part)
                }
                if let rating = item.communityRating {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text(verbatim: "★ " + String(format: "%.1f", rating))
                        .foregroundStyle(Color.dionysusGold)
                        .accessibilityLabel(String(localized: "Rated: \(String(format: "%.1f", rating)) stars"))
                }
            }
            .font(.callout.weight(.semibold))
            if showsBadges, !item.metadataBadges.isEmpty {
                HStack(spacing: 12) {
                    ForEach(item.metadataBadges, id: \.self) { badge in
                        Text(verbatim: badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5), lineWidth: 2))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        let title = Text(verbatim: item.name).font(.system(size: 76, weight: .bold)).lineLimit(2).minimumScaleFactor(0.5)
        if let url = item.logoImageURL {
            LogoImageView(url: url, fallback: title, retryPatience: .extended)
        } else {
            title
        }
    }
}
```

`DionysusTV/Browse/Detail/TVDetailActions.swift`:

```swift
import SwiftUI

enum TVDetailFocus {
    static let play = "action.play"
    static let restart = "action.restart"
    static let watched = "action.watched"
    static let favorite = "action.favorite"
    static let overview = "overview"
}

/// Play or Resume, Restart, Watched and Favorite. There is no More button:
/// M3 has nothing to put in it.
///
/// `playTarget` is what plays (the movie, or the show's resolved episode;
/// `nil` when a show has nothing to play, where the Play button isn't
/// drawn). `statusTarget` is what Watched and Favorite act on: the movie, or
/// the show itself rather than the episode.
struct TVDetailActions: View {
    let viewModel: AssetDetailViewModel
    let playTarget: MediaItem?
    let statusTarget: MediaItem
    let isShow: Bool
    let focus: FocusState<String?>.Binding
    let play: (PlaybackRequest) -> Void

    /// The ids in the order drawn, for the page's `tvClaimsFocus`.
    static func focusIDs(playTarget: MediaItem?) -> [String] {
        guard let playTarget else { return [TVDetailFocus.watched, TVDetailFocus.favorite] }
        let hasResume = (playTarget.resumePositionSeconds ?? 0) > 0 && !playTarget.isPlayed
        return [TVDetailFocus.play] + (hasResume ? [TVDetailFocus.restart] : []) + [TVDetailFocus.watched, TVDetailFocus.favorite]
    }

    private var hasResume: Bool {
        guard let playTarget else { return false }
        return (playTarget.resumePositionSeconds ?? 0) > 0 && !playTarget.isPlayed
    }

    var body: some View {
        HStack(spacing: 22) {
            if let playTarget, let title = TVDetailFormat.playTitle(target: playTarget, isShow: isShow) {
                Button {
                    play(PlaybackRequest(itemID: playTarget.id, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: playTarget.id)))
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "play.fill").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: title)
                            if hasResume, let left = TVDetailFormat.timeLeft(runTimeTicks: playTarget.dto.runTimeTicks, resumeSeconds: playTarget.resumePositionSeconds) {
                                HStack(spacing: 12) {
                                    ProgressView(value: playTarget.playedFraction ?? 0).tint(.dionysusHighlight).frame(width: 120)
                                    Text(verbatim: left).font(.caption.weight(.semibold))
                                }
                                .opacity(0.8)
                            }
                        }
                    }
                    .frame(minWidth: 320, alignment: .leading)
                }
                .focused(focus, equals: TVDetailFocus.play)
                .accessibilityIdentifier(A11yID.TV.Detail.play)

                if hasResume {
                    Button {
                        play(PlaybackRequest(itemID: playTarget.id, startFromBeginning: true, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: playTarget.id)))
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .focused(focus, equals: TVDetailFocus.restart)
                    .accessibilityLabel(String(localized: "Restart"))
                    .accessibilityIdentifier(A11yID.TV.Detail.restart)
                }
            }

            Button {
                Task { await viewModel.toggleWatched(itemID: statusTarget.id, currentlyWatched: statusTarget.isPlayed) }
            } label: {
                // The eye, never a tick.
                Image(systemName: statusTarget.isPlayed ? "eye.fill" : "eye")
            }
            .focused(focus, equals: TVDetailFocus.watched)
            .accessibilityLabel(statusTarget.isPlayed ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched"))
            .accessibilityIdentifier(A11yID.TV.Detail.watched)

            Button {
                Task { await viewModel.toggleFavorite(itemID: statusTarget.id, currentlyFavorite: statusTarget.isFavorite) }
            } label: {
                Image(systemName: statusTarget.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(statusTarget.isFavorite ? Color.dionysusFavorite : .primary)
            }
            .focused(focus, equals: TVDetailFocus.favorite)
            .accessibilityLabel(statusTarget.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
            .accessibilityIdentifier(A11yID.TV.Detail.favorite)
        }
        .focusSection()
    }
}
```

`DionysusTV/Browse/Detail/TVMovieDetailView.swift`:

```swift
import SwiftUI

/// A movie's page (prototype screen 7): the header and actions fill the
/// first screen over the backdrop; Cast & Crew, More Like This and Details
/// scroll up from below.
struct TVMovieDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @Environment(\.tvOpenRoute) private var open
    @FocusState private var focus: String?
    @State private var showsFullOverview = false

    private var focusIDs: [String] {
        TVDetailActions.focusIDs(playTarget: item)
            + (item.hasDescription ? [TVDetailFocus.overview] : [])
            + viewModel.similar.map { "similar.\($0.id)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                VStack(alignment: .leading, spacing: 22) {
                    TVDetailHeader(item: item)
                    if let overview = item.overview, item.hasDescription {
                        Button { showsFullOverview = true } label: {
                            Text(verbatim: overview).lineLimit(3).multilineTextAlignment(.leading).frame(width: 900, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .focused($focus, equals: TVDetailFocus.overview)
                        .accessibilityIdentifier(A11yID.TV.Detail.overview)
                    }
                    if let credits = starringLine {
                        Text(verbatim: credits).font(.caption).foregroundStyle(.secondary).frame(width: 900, alignment: .leading)
                    }
                    TVDetailActions(viewModel: viewModel, playTarget: item, statusTarget: item, isShow: false, focus: $focus, play: play)
                        .padding(.top, 16)
                }
                // The first screen: the rails start below the fold.
                .frame(minHeight: 860, alignment: .bottomLeading)

                if !item.cast.isEmpty {
                    castRail
                }
                if !viewModel.similar.isEmpty {
                    TVRail(title: String(localized: "More Like This")) {
                        ForEach(viewModel.similar) { similar in
                            TVPosterTile(item: similar, caption: .always, identifier: A11yID.TV.Detail.similar(similar.id)) {
                                open(.assetDetail(itemID: similar.id, preloadedItem: similar))
                            }
                            .focused($focus, equals: "similar.\(similar.id)")
                        }
                    }
                }
                if let details = item.technicalDetails, !details.isEmpty {
                    detailsBlock(details)
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 160)
        }
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        .fullScreenCover(isPresented: $showsFullOverview) {
            TVFullOverview(title: item.name, overview: item.overview ?? "")
        }
    }

    private func play(_ request: PlaybackRequest) {
        TVPlayerPresenter.present(request, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }

    /// "Starring A, B, C · Directed by D", from the item's people.
    private var starringLine: String? {
        let cast = item.cast
        let actors = cast.filter { $0.role != nil }.prefix(3).map(\.name)
        guard !actors.isEmpty else { return nil }
        return String(localized: "Starring \(actors.joined(separator: ", "))")
    }

    /// Not selectable: there is no person page. The row is still a scroll
    /// view, moved by focus on the rails above and below it.
    private var castRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 56) {
                    ForEach(item.cast) { member in
                        VStack(spacing: 14) {
                            AsyncRemoteImage(url: member.imageURL, placeholderSystemImage: "person.fill")
                                .frame(width: 180, height: 180)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                            Text(verbatim: member.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let role = member.role {
                                Text(verbatim: role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 180)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }

    private func detailsBlock(_ details: TechnicalDetails) -> some View {
        let rows: [(String, String?)] = [
            (String(localized: "Studio"), item.studios.first),
            (String(localized: "Released"), item.metadataDateText),
            (String(localized: "Genres"), item.genres.isEmpty ? nil : item.genres.joined(separator: ", ")),
            (String(localized: "Rating"), item.ageRating),
            (String(localized: "Video"), [details.resolution, details.dynamicRange].compactMap { $0 }.joined(separator: " · ")),
            (String(localized: "Audio"), details.audioTracks.first),
            (String(localized: "Subtitles"), details.subtitleTracks.isEmpty ? nil : details.subtitleTracks.joined(separator: ", ")),
            (String(localized: "Runtime"), item.durationText)
        ]
        return VStack(alignment: .leading, spacing: 24) {
            Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 4), alignment: .leading, spacing: 30) {
                ForEach(rows.filter { !($0.1 ?? "").isEmpty }, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: label.uppercased()).font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: value ?? "").lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(30)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(.trailing, 80)
    }
}

/// The whole overview, for one too long for three lines. Menu closes it.
struct TVFullOverview: View {
    let title: String
    let overview: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(verbatim: title).font(.title2.bold())
            ScrollView { Text(verbatim: overview).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Close") { dismiss() }.focused($closeFocused)
        }
        .padding(120)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($closeFocused, true)
    }
}
```

Check `MediaItem.cast`'s roles before settling `starringLine`: if directors carry a `role` of "Director", exclude them from "Starring" and append `" · " + String(localized: "Directed by \(name)")`, as the prototype shows. Follow what `MediaItem.cast` actually returns.

- [ ] **Step 8: Add the failing-detail scenario to the stub**

In `UITestStubURLProtocol.swift`, find how the existing scenarios branch (search for `slowPlaybackInfo`) and add a `failingDetail` scenario the same way: under it, `GET /Users/{id}/Items/{itemID}` answers HTTP 500 for `UITestFixtureIdentity.movieID(3)` only. Every other request behaves as `standard`.

- [ ] **Step 9: Write the journeys**

Add to `DionysusTVUITests/Support/TVShellJourney.swift`:

```swift
    /// A tile opens its detail page, with focus on Play (or Resume).
    @discardableResult
    func openDetailFromFocusedTile(_ app: XCUIApplication) -> XCUIElement {
        press(.select)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play), "A detail page opens with focus on Play")
        return play
    }

    /// Tile, then Play on its detail page: the way to the player since M3.
    func playFromFocusedTile(_ app: XCUIApplication) {
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
    }
```

`DionysusTVUITests/DetailJourneyTests.swift`:

```swift
import XCTest

/// Detail pages inside the shell: a tile opens one beside the rail, Menu pops
/// it back to the tile, and a More Like This chain past the keep-alive cap
/// unwinds one page at a time.
final class DetailJourneyTests: TVUITestCase {
    func test_tile_opensItsDetailPage_besideTheRail_andMenuReturnsToTheTile() {
        let app = launchAtHome()
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        openDetailFromFocusedTile(app)
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail stays beside a detail page")
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.restart].exists, "A part-watched movie offers Restart")

        press(.menu)
        XCTAssertTrue(waitForFocus(tile), "Menu pops the page and focus returns to the tile")
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].exists)
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Menu popped; it did not open the rail")
    }

    func test_menuOnTheRootPage_stillOpensTheRail() {
        let app = launchAtHome()
        openDetailFromFocusedTile(app)
        press(.menu)
        press(.menu)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]), "With the path empty, Menu opens the rail")
    }

    func test_play_thenMenu_returnsToTheDetailPage() {
        let app = launchAtHome()
        let play = openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]))
    }

    func test_watched_andFavorite_toggle() {
        let app = launchAtHome()
        openDetailFromFocusedTile(app)
        let watched = app.buttons[A11yID.TV.Detail.watched]
        let before = watched.label
        for _ in 0..<3 where !watched.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(watched))
        press(.select)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: watched)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed)
    }

    /// Review Focus 2. Six pages deep is past the cap (four live pages), so
    /// the first detail pages are torn down and rebuilt on the way back.
    func test_moreLikeThisChain_pastTheCap_unwindsToTheRootTile() {
        let app = launchAtHome()
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        openDetailFromFocusedTile(app)
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.similar."))
        for depth in 2...6 {
            // Down from the actions to More Like This, past the overview.
            for _ in 0..<6 where !(similar.firstMatch.exists && similar.firstMatch.hasFocus) { press(.down) }
            XCTAssertTrue(waitForFocus(similar.firstMatch), "Depth \(depth): More Like This is reachable")
            press(.select)
            XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "Depth \(depth): the next page opens on Play")
        }
        for depth in stride(from: 6, to: 1, by: -1) {
            press(.menu)
            let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(focused.waitForExistence(timeout: 5), "Back from depth \(depth): focus is on something")
            XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Back from depth \(depth): the rail did not open")
        }
        press(.menu)
        XCTAssertTrue(waitForFocus(tile), "The last Menu lands on the tile the chain started from")
    }

    /// Review Focus 5.
    func test_failedDetail_showsRetry_andMenuPops() {
        let app = launchAtHome(scenario: "failingDetail")
        _ = openMovies(app)
        let failing = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.movieID(3))]
        for _ in 0..<12 where !failing.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(failing))
        press(.select)
        let retry = app.buttons[A11yID.TV.Detail.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(retry), "Retry takes focus, so Menu has somewhere to go from")
        press(.menu)
        XCTAssertTrue(waitForFocus(failing))
    }
}
```

The failing-detail journey needs the tile to open with no preloaded item, or the page shows the preloaded one. In `TVDetailPage.content`, the failure branch must also run when `item` is the preloaded one and the load failed: change the first condition to `if let item = viewModel.item, viewModel.loadState != .failed…` by matching on the state first:

```swift
        if case .failed(let message) = viewModel.loadState {
            TVPageMessage(…)
        } else if let item = viewModel.item {
            …
        } else {
            ProgressView()…
        }
```

Update the M2 journeys that select a tile and expect the player, using `playFromFocusedTile(app)` in place of `press(.select)` plus the elapsed-label wait:
- `PlayerJourneyTests`: all five tests (and its `openPlayer` helper). After `press(.menu)` the assertion becomes focus on `A11yID.TV.Detail.play`, not the tile.
- `PlayerReturnJourneyTests`: `test_player_overHome…` and `test_player_overALibrary…` and `test_player_fromBelowTheFirstScreen…` become "detail page over …": select the tile, assert the detail page, Menu, then the existing return assertions (focus or lift on the tile, the grid not back at the top). Rename them `test_detail_overHome_returnsToTheTile` and so on. `test_search_keepsItsQueryAndResults…` opens the detail page, pops, and asserts the query and result as before.
- `SearchJourneyTests.test_searchFromSidebar_findsTitle_andPlaysIt`: after selecting the result, assert `A11yID.TV.Detail.play` has focus, then Select and assert the player. Rename it `…_andOpensItsDetailPage`.
- `BrowseJourneyTests`: unchanged.

- [ ] **Step 10: Run everything for this PR**

Run, one after another: tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: all PASS. If `hasFocus` reads false for a tile after a pop though focus is there, read the lifted frame instead, as `PlayerReturnJourneyTests.waitForLift` does.

- [ ] **Step 11: Measure the keep-alive cap**

On the Simulator, with the LAN test server (memory `jellyfin-test-server`), in a Debug build:
1. Record the app's memory footprint (`xcrun simctl spawn booted log` is not needed; use Xcode's memory gauge or `footprint $(pgrep -x Dionysus)`) on Home, then at path depth 1, 3 and 10 through More Like This, then back on Home after ten pops.
2. Scroll a library grid four screens down at depth 0 and again with three pages beneath it; note any hitch.

Write the six numbers and the hitch observation into the PR description. Expected: growth of roughly 20–50MB per live page up to depth 3, flat from 4 to 10, and back within about 20MB of the starting figure after the pops. If depth 3 costs more than 250MB over Home, stop and tell Benjamin: the spec's fallback is to keep only the root alive (`liveBeneathTop = 0`). The Bedroom Apple TV check waits for his next authorised deploy; add it to memory `open-issues-and-follow-ups`.

- [ ] **Step 12: Docs**

In `CLAUDE.md`'s tvOS section, replace the paragraph beginning "**Only the page on show is built, and the player is laid over it**" from its sentence "M3's details page is a page *within* the shell…" with: pushed pages live on `TVShellNavigation.path`; Menu pops before it opens the rail; the root, the top and the two beneath the top stay built (`TVPageKeepAlive`), hidden and disabled; a hidden page claims no focus and refreshes when it comes back on show (`tvPageIsOnShow`); choosing a rail row drops the path; pushing and popping hold the rail, or tvOS hands focus to it. In `TESTING.md`'s tvOS section add `DetailJourneyTests`, the `failingDetail` scenario, and the two helpers.

- [ ] **Step 13: Sync strings, commit, PR**

Build once in Xcode (Cmd+B) so `Localizable.xcstrings` picks up the new strings. After sign-off:

```bash
git add DionysusTV DionysusTVTests DionysusTVUITests DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md
git commit -m "Open detail pages inside the Apple TV shell, starting with movies"
```

Open PR 1 against `develop`; merge with `--merge` once checks pass.

---

## PR 2 — show, box set and playlist pages

### Task 5: The show page

**Files:**
- Create: `DionysusTV/Browse/Detail/TVSeasonEpisodesModel.swift`, `DionysusTV/Browse/Detail/TVShowDetailView.swift`
- Modify: `DionysusTV/Browse/Detail/TVDetailPage.swift`, `AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests/TVSeasonEpisodesModelTests.swift`, `DionysusTVUITests/ShowDetailJourneyTests.swift`

**Interfaces:**
- Consumes: `AssetDetailViewModel.seasons`, `.seriesID`, `.seriesItem`, `.showPlaybackEpisode`, `.initialSeasonID`, `.isShowWithoutPlayableEpisode`, `.episodeListRefreshToken`; `JellyfinAPIClient.episodes(seriesID:seasonID:userID:fields:)`; `TVDetailActions`, `TVDetailHeader`, `TVLandscapeTile`, `TVRail`.
- Produces:
  - `@MainActor @Observable final class TVSeasonEpisodesModel { init(client: JellyfinAPIClient, userID: String, seriesID: String); private(set) var episodes: [String: [MediaItem]]; private(set) var failedSeasons: Set<String>; func load(seasonID: String, force: Bool = false) async }`
  - `TVShowDetailView(viewModel:item:client:userID:rememberedFocus:)`, same parameters as `TVMovieDetailView`.
  - `A11yID.TV.Detail.season(_:)`, `.episode(_:)`, `.noEpisodes`.

- [ ] **Step 1: Write the failing unit test**

`DionysusTVTests/TVSeasonEpisodesModelTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVSeasonEpisodesModelTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeModel() -> TVSeasonEpisodesModel {
        let client = JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession())
        return TVSeasonEpisodesModel(client: client, userID: "user-1", seriesID: "series-1")
    }

    private func episodesResponse(_ request: URLRequest, _ ids: [String]) throws -> (HTTPURLResponse, Data) {
        let items = ids.map { BaseItemDto(id: $0, name: $0, type: .episode) }
        return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
    }

    func test_load_fetchesOneSeason_once() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            XCTAssertTrue(request.url?.query?.contains("seasonId=s1") ?? false)
            return try self.episodesResponse(request, ["e1", "e2"])
        }
        let model = makeModel()
        await model.load(seasonID: "s1")
        await model.load(seasonID: "s1")
        XCTAssertEqual(model.episodes["s1"]?.map(\.id), ["e1", "e2"])
        XCTAssertEqual(requests, 1, "A season already loaded isn't fetched again")
    }

    func test_forcedLoad_refetches() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try self.episodesResponse(request, ["e1"])
        }
        let model = makeModel()
        await model.load(seasonID: "s1")
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(requests, 2)
    }

    /// Review Focus 4: a season that exists with no episodes is an empty
    /// list, not a failure.
    func test_emptySeason_isLoadedAndEmpty() async throws {
        MockURLProtocol.requestHandler = { request in try self.episodesResponse(request, []) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        XCTAssertEqual(model.episodes["s1"]?.count, 0)
        XCTAssertFalse(model.failedSeasons.contains("s1"))
    }

    func test_failure_isRecorded_andALaterLoadClearsIt() async throws {
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        XCTAssertTrue(model.failedSeasons.contains("s1"))
        XCTAssertNil(model.episodes["s1"])

        MockURLProtocol.requestHandler = { request in try self.episodesResponse(request, ["e1"]) }
        await model.load(seasonID: "s1")
        XCTAssertFalse(model.failedSeasons.contains("s1"))
        XCTAssertEqual(model.episodes["s1"]?.count, 1)
    }
}
```

Match `MockURLProtocol`'s handler return type and the query item's spelling (`seasonId`) to `JellyfinAPIClient.episodes` and the existing tests (`DionysusPlayerTests/Features/Collection/`).

- [ ] **Step 2: Run it and see it fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVSeasonEpisodesModelTests`. Expected: build fails, "cannot find 'TVSeasonEpisodesModel' in scope".

- [ ] **Step 3: Implement the model**

`DionysusTV/Browse/Detail/TVSeasonEpisodesModel.swift`:

```swift
import Foundation
import Observation

/// One show's episodes, a season at a time, for the show page's rail. iOS
/// keeps this inside `SeasonEpisodeList`, a view; on the Apple TV the shell
/// tears pages down and rebuilds them, so it lives in a model the page owns.
@MainActor
@Observable
final class TVSeasonEpisodesModel {
    private(set) var episodes: [String: [MediaItem]] = [:]
    private(set) var failedSeasons: Set<String> = []

    private let client: JellyfinAPIClient
    private let userID: String
    private let seriesID: String

    init(client: JellyfinAPIClient, userID: String, seriesID: String) {
        self.client = client
        self.userID = userID
        self.seriesID = seriesID
    }

    /// Fetches a season once; `force` refetches it after playback or a
    /// watched change, keeping what's shown until the new list lands.
    func load(seasonID: String, force: Bool = false) async {
        guard force || episodes[seasonID] == nil else { return }
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID, fields: JellyfinAPIClient.detailFields)
            episodes[seasonID] = result.items.map { MediaItem(dto: $0, images: images) }
            failedSeasons.remove(seasonID)
        } catch {
            if episodes[seasonID] == nil { failedSeasons.insert(seasonID) }
        }
    }
}
```

Run the unit tests. Expected: PASS.

- [ ] **Step 4: Write the show page**

Add to `A11yID.TV.Detail`:

```swift
            static func season(_ seasonID: String) -> String { "tv.detail.season.\(seasonID)" }
            static func episode(_ episodeID: String) -> String { "tv.detail.episode.\(episodeID)" }
            static let noEpisodes = "tv.detail.noEpisodes"
```

`DionysusTV/Browse/Detail/TVShowDetailView.swift`:

```swift
import SwiftUI

/// A show's page (prototype screen 8): header and actions, season tabs, and
/// the chosen season's episodes as a rail. Select on an episode plays it.
///
/// `item` is the series, or the episode when the page was opened on one (a
/// Continue Watching tile): its own overview and artwork show, while Watched
/// and Favorite act on the show (`seriesItem`).
struct TVShowDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @FocusState private var focus: String?
    @State private var selectedSeasonID: String?
    @State private var episodes: TVSeasonEpisodesModel?

    /// The episode Play targets: the episode the page was opened on, or the
    /// one the view model resolved for the show.
    private var playTarget: MediaItem? {
        item.kind == .episode ? item : viewModel.showPlaybackEpisode
    }

    private var seasonID: String? { selectedSeasonID ?? viewModel.initialSeasonID }
    private var seasonEpisodes: [MediaItem] { seasonID.flatMap { episodes?.episodes[$0] } ?? [] }

    private var focusIDs: [String] {
        TVDetailActions.focusIDs(playTarget: playTarget)
            + viewModel.seasons.map { "season.\($0.id)" }
            + seasonEpisodes.map { "episode.\($0.id)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 20) {
                TVDetailHeader(item: viewModel.seriesItem ?? item, showsBadges: false)
                if let overview = item.overview, item.hasDescription {
                    Text(verbatim: overview).lineLimit(2).frame(width: 900, alignment: .leading).foregroundStyle(.white.opacity(0.82))
                }
                TVDetailActions(
                    viewModel: viewModel, playTarget: playTarget, statusTarget: viewModel.seriesItem ?? item,
                    isShow: true, focus: $focus, play: play
                )
            }
            .frame(maxHeight: .infinity, alignment: .bottomLeading)

            if viewModel.seasons.count > 1 {
                seasonTabs
            }
            episodeRail
        }
        .padding(.top, 60)
        .padding(.bottom, 60)
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        .task(id: viewModel.seriesID) {
            guard let seriesID = viewModel.seriesID, episodes == nil else { return }
            episodes = TVSeasonEpisodesModel(client: client, userID: userID, seriesID: seriesID)
        }
        .task(id: "\(seasonID ?? "")-\(episodes == nil)") {
            if let seasonID { await episodes?.load(seasonID: seasonID) }
        }
        // Bumped by `refreshItem()` after playback or a watched change.
        .onChange(of: viewModel.episodeListRefreshToken) {
            guard let seasonID else { return }
            Task { await episodes?.load(seasonID: seasonID, force: true) }
        }
    }

    private var seasonTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(viewModel.seasons) { season in
                    Button { selectedSeasonID = season.id } label: {
                        Text(verbatim: season.name)
                            .fontWeight(season.id == seasonID ? .bold : .regular)
                    }
                    .focused($focus, equals: "season.\(season.id)")
                    .accessibilityAddTraits(season.id == seasonID ? .isSelected : [])
                    .accessibilityIdentifier(A11yID.TV.Detail.season(season.id))
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    @ViewBuilder
    private var episodeRail: some View {
        if let seasonID, episodes?.failedSeasons.contains(seasonID) == true {
            Text("Couldn't load this season's episodes.").foregroundStyle(.secondary).frame(height: 330, alignment: .top)
        } else if let seasonID, episodes?.episodes[seasonID]?.isEmpty == true {
            Text("No episodes yet.")
                .foregroundStyle(.secondary)
                .frame(height: 330, alignment: .top)
                .accessibilityIdentifier(A11yID.TV.Detail.noEpisodes)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(seasonEpisodes) { episode in
                        TVLandscapeTile(
                            item: episode, size: TVTileMetrics.episode,
                            title: episode.numberedEpisodeName,
                            subtitle: [episode.episodeLabel, episode.durationText].compactMap { $0 }.joined(separator: " · "),
                            identifier: A11yID.TV.Detail.episode(episode.id)
                        ) {
                            play(PlaybackRequest(itemID: episode.id))
                        }
                        .focused($focus, equals: "episode.\(episode.id)")
                    }
                }
                .padding(.vertical, 20)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
            .frame(height: 370)
        }
    }

    private func play(_ request: PlaybackRequest) {
        TVPlayerPresenter.present(request, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }
}
```

In `TVDetailPage.content`, replace the `.series, .season, .episode` branch's stand-in with `TVShowDetailView(viewModel: viewModel, item: item, client: client, userID: userID, rememberedFocus: $rememberedFocus)`.

- [ ] **Step 5: Write the journeys**

`DionysusTVUITests/ShowDetailJourneyTests.swift`:

```swift
import XCTest

final class ShowDetailJourneyTests: TVUITestCase {
    /// Opens the fixture series from the TV Shows library, the row below
    /// Movies in the rail.
    private func openSeries(_ app: XCUIApplication) {
        openRailFromHome(app)
        let shows = app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.showsLibraryID)]
        pressDown(until: shows)
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.seriesID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
        openDetailFromFocusedTile(app)
    }

    func test_show_namesTheEpisodeOnPlay_andListsTheSeasonsEpisodes() {
        let app = launchAtHome()
        openSeries(app)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].label.contains("S1:E1"), "Play names the episode it starts")
        let first = app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
    }

    func test_seasonTab_switchesTheEpisodeRail() {
        let app = launchAtHome()
        openSeries(app)
        let seasonTwo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.season.")).element(boundBy: 1)
        XCTAssertTrue(seasonTwo.waitForExistence(timeout: 10))
        press(.down)
        press(.right)
        XCTAssertTrue(waitForFocus(seasonTwo))
        press(.select)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 2, episode: 1))].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 1, episode: 1))].exists)
    }

    func test_episodeTile_plays_andMenuReturnsToIt() {
        let app = launchAtHome()
        openSeries(app)
        let second = app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 1, episode: 2))]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        press(.down, times: 2)
        press(.right)
        XCTAssertTrue(waitForFocus(second))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(second.waitForExistence(timeout: 5), "Back on the show page, not the library")
    }

    /// A Continue Watching episode tile opens its show's page on that
    /// episode, as iOS does.
    func test_episodeTileOnHome_opensItsShowPage() {
        let app = launchAtHome()
        let episodeTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]
        press(.right)
        XCTAssertTrue(waitForFocus(episodeTile))
        openDetailFromFocusedTile(app)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 1, episode: 1))].waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 6: Run and commit**

Run: tvOS unit, then tvOS UI. Expected: PASS. After sign-off:

```bash
git add DionysusTV/Browse/Detail DionysusTVTests/TVSeasonEpisodesModelTests.swift DionysusTVUITests/ShowDetailJourneyTests.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift
git commit -m "Add the show page to the Apple TV app"
```

### Task 6: Box set and playlist pages

**Files:**
- Create: `DionysusTV/Browse/Detail/TVBoxSetDetailView.swift`, `DionysusTV/Browse/Detail/TVPlaylistDetailView.swift`
- Modify: `DionysusTV/Browse/Detail/TVDetailPage.swift`, `AccessibilityIdentifiers.swift`, `UITestStubURLProtocol.swift` (an `emptyPlaylist` scenario)
- Test: `DionysusTVUITests/CollectionDetailJourneyTests.swift`

**Interfaces:**
- Consumes: `AssetDetailViewModel.collectionItems`, `.orderedPlaylistItems`, `.playlistResumeTarget`; `TVPosterTile`, `TVLandscapeTile`, `TVPlayerPresenter.present(_:queue:…)`.
- Produces: `TVBoxSetDetailView(viewModel:item:rememberedFocus:)`, `TVPlaylistDetailView(viewModel:item:client:userID:rememberedFocus:)`, `A11yID.TV.Detail.member(_:)`, `.emptyMessage`.

- [ ] **Step 1: Write the failing journeys**

`DionysusTVUITests/CollectionDetailJourneyTests.swift`:

```swift
import XCTest

final class CollectionDetailJourneyTests: TVUITestCase {
    private func openLibrary(_ app: XCUIApplication, _ libraryID: String, firstTile itemID: String) {
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(libraryID)])
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(itemID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
        press(.select)
    }

    private var members: XCUIElementQuery {
        XCUIApplication().buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.member."))
    }

    /// A box set lists its movies; each opens its own detail page, and Menu
    /// comes back to the box set, then to the library.
    func test_boxSet_listsItsMovies_andEachOpensItsDetailPage() {
        let app = launchAtHome()
        openLibrary(app, UITestFixtureIdentity.boxSetsLibraryID, firstTile: UITestFixtureIdentity.boxSetID)
        let first = members.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(first), "A box set has no Play button: focus starts on its first movie")
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.menu)
        XCTAssertTrue(waitForFocus(first))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.boxSetID)]))
    }

    /// A playlist plays from its Play button and from any row.
    func test_playlist_playsFromPlay_andFromARow() {
        let app = launchAtHome()
        openLibrary(app, UITestFixtureIdentity.playlistsLibraryID, firstTile: UITestFixtureIdentity.secondPlaylistID)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 5))

        press(.down)
        XCTAssertTrue(waitForFocus(members.firstMatch))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10), "A playlist's row plays; it doesn't open a detail page")
    }

    /// Review Focus 4.
    func test_emptyPlaylist_showsMessage_andMenuPops() {
        let app = launchAtHome(scenario: "emptyPlaylist")
        openLibrary(app, UITestFixtureIdentity.playlistsLibraryID, firstTile: UITestFixtureIdentity.secondPlaylistID)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Detail.emptyMessage].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].exists, "No Play button with nothing to play")
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.secondPlaylistID)]))
    }
}
```

Which playlist sorts first in the Playlists library depends on the stub's order (`UITestFixtureLibrary.playlists`); use the first one's id in both playlist tests. Add the `emptyPlaylist` scenario to `UITestStubURLProtocol`: `GET /Playlists/{id}/Items` answers an empty result for every playlist.

- [ ] **Step 2: Run them and see them fail**

Run: tvOS UI with `-only-testing:DionysusTVUITests/CollectionDetailJourneyTests`. Expected: FAIL, no `tv.detail.member.` elements (the box set renders as a movie page).

- [ ] **Step 3: Implement**

Add to `A11yID.TV.Detail`:

```swift
            static func member(_ id: String) -> String { "tv.detail.member.\(id)" }
            static let emptyMessage = "tv.detail.empty"
```

`DionysusTV/Browse/Detail/TVBoxSetDetailView.swift`:

```swift
import SwiftUI

/// A box set: its name and overview, then its movies as a poster grid. Each
/// opens its own detail page; the set itself has nothing to play.
struct TVBoxSetDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    @Binding var rememberedFocus: String?
    @Environment(\.tvOpenRoute) private var open
    @FocusState private var focus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(item: item, showsBadges: false)
                if let overview = item.overview, item.hasDescription {
                    Text(verbatim: overview).lineLimit(3).frame(width: 900, alignment: .leading).foregroundStyle(.white.opacity(0.82))
                }
                if viewModel.collectionItems.isEmpty, viewModel.loadState == .loaded {
                    TVDetailEmptyMessage(text: String(localized: "This collection is empty."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 48, alignment: .leading)], alignment: .leading, spacing: 60) {
                        ForEach(viewModel.collectionItems) { member in
                            TVPosterTile(item: member, caption: .always, identifier: A11yID.TV.Detail.member(member.id)) {
                                open(.assetDetail(itemID: member.id, preloadedItem: member))
                            }
                            .focused($focus, equals: member.id)
                        }
                    }
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 160)
            .padding(.trailing, 80)
        }
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: viewModel.collectionItems.map(\.id), remembered: $rememberedFocus)
    }
}

/// Shown in place of an empty box set's or playlist's items. It is
/// focusable, so the page has somewhere for focus to be and Menu still pops:
/// with focus nowhere, tvOS delivers Menu to nothing.
struct TVDetailEmptyMessage: View {
    let text: String
    @FocusState private var focused: String?
    @State private var remembered: String?

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.vertical, 16)
            .focusable()
            .focused($focused, equals: "empty")
            .accessibilityIdentifier(A11yID.TV.Detail.emptyMessage)
            .tvClaimsFocus($focused, ids: ["empty"], remembered: $remembered)
    }
}
```

`DionysusTV/Browse/Detail/TVPlaylistDetailView.swift`:

```swift
import SwiftUI

/// A playlist, read-only in M3: Play or Resume, then its items in order. A
/// row plays that item with the playlist as the queue, as iOS's rows do; it
/// doesn't open a detail page.
struct TVPlaylistDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @FocusState private var focus: String?

    private var items: [MediaItem] { viewModel.orderedPlaylistItems }

    /// Keyed on the playlist entry, not the item: the same item can be in a
    /// playlist twice.
    private func key(_ member: MediaItem) -> String { "member.\(member.playlistItemID ?? member.id)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(item: item, showsBadges: false)
                if let target = viewModel.playlistResumeTarget {
                    Button { play(target) } label: {
                        Label(TVDetailFormat.playTitle(target: target, isShow: false) ?? String(localized: "Play"), systemImage: "play.fill")
                            .frame(minWidth: 320, alignment: .leading)
                    }
                    .focused($focus, equals: TVDetailFocus.play)
                    .accessibilityIdentifier(A11yID.TV.Detail.play)
                } else if viewModel.loadState == .loaded {
                    TVDetailEmptyMessage(text: String(localized: "This playlist is empty."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 440, maximum: 440), spacing: 44, alignment: .leading)], alignment: .leading, spacing: 50) {
                    ForEach(items, id: \.playlistItemID) { member in
                        TVLandscapeTile(
                            item: member, size: TVTileMetrics.episode,
                            title: member.railTitle, subtitle: member.railSubtitle,
                            identifier: A11yID.TV.Detail.member(member.playlistItemID ?? member.id)
                        ) { play(member) }
                        .focused($focus, equals: key(member))
                    }
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 160)
            .padding(.trailing, 80)
        }
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: (viewModel.playlistResumeTarget == nil ? [] : [TVDetailFocus.play]) + items.map(key), remembered: $rememberedFocus)
    }

    private func play(_ member: MediaItem) {
        TVPlayerPresenter.present(PlaybackRequest(itemID: member.id), queue: items, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }
}
```

In `TVDetailPage.content`, add the two kinds to the switch, above `default`:

```swift
            case .boxSet:
                TVBoxSetDetailView(viewModel: viewModel, item: item, rememberedFocus: $rememberedFocus)
            case .playlist:
                TVPlaylistDetailView(viewModel: viewModel, item: item, client: client, userID: userID, rememberedFocus: $rememberedFocus)
```

- [ ] **Step 4: Run, document, commit, PR**

Run: tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: PASS. Add the two journey classes and the `emptyPlaylist` scenario to `TESTING.md`; add a sentence to CLAUDE.md's tvOS section: show pages keep their episodes in `TVSeasonEpisodesModel`, box set tiles open detail pages, playlist rows play with the playlist as the queue. Sync strings in Xcode. After sign-off:

```bash
git add DionysusTV/Browse/Detail DionysusTVUITests/CollectionDetailJourneyTests.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md
git commit -m "Add box set and playlist pages to the Apple TV app"
```

Open PR 2; merge with `--merge` once checks pass.

---

## PR 3 — the collection grid

### Task 7: The grid, its pills and the alphabet bar

**Files:**
- Create: `DionysusTV/Browse/TVAlphabetIndex.swift`, `DionysusTV/Browse/TVCollectionGridView.swift`
- Delete: `DionysusTV/Browse/TVLibraryGridView.swift`
- Modify: `DionysusTV/Browse/TVMainView.swift` (both call sites), `AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests/TVAlphabetIndexTests.swift`, `DionysusTVUITests/CollectionGridJourneyTests.swift`; existing `SidebarJourneyTests.test_emptyLibrary_leavesFocusOnItsRow`

**Interfaces:**
- Consumes: `CollectionGridViewModel` (`filteredItems`, `items`, `loadState`, `sortField`, `sortOrder`, `selected*`, `available*`, `set*Filter`, `setSortField`, `setSortOrder`, `resetFilters`, `hasActiveFilters`, `load()`, `loadIfNeeded()`, `query`).
- Produces:
  - `enum TVAlphabetIndex { static let letters: [Character]; static func letter(for name: String) -> Character; static func firstItemIDs(_ items: [(id: String, name: String)]) -> [Character: String] }`
  - `TVCollectionGridView(title: String, titleIdentifier: String, viewModel: CollectionGridViewModel, rememberedItemID: Binding<String?>)`
  - `A11yID.TV.Library`: `count`, `sort`, `filter(_:)`, `letter(_:)`, `resetFilters`, `retry`. `title(_:)` and `tile(_:)` are unchanged.

- [ ] **Step 1: Write the failing unit tests**

`DionysusTVTests/TVAlphabetIndexTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// Review Focus 3: every title lands under a letter the bar shows.
final class TVAlphabetIndexTests: XCTestCase {
    func test_theBarIsHashThenAToZ() {
        XCTAssertEqual(TVAlphabetIndex.letters.count, 27)
        XCTAssertEqual(TVAlphabetIndex.letters.first, "#")
        XCTAssertEqual(TVAlphabetIndex.letters.last, "Z")
    }

    func test_plainTitles() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Dracula"), "D")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "sahara"), "S")
    }

    /// Jellyfin's sort name drops a leading article, so the grid's order does
    /// too: "The Boy in the Plastic Bubble" sits among the Bs.
    func test_leadingArticles_areSkipped() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "The Boy in the Plastic Bubble"), "B")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "A Quiet Place"), "Q")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "An Education"), "E")
        // Not an article: the word only starts with one.
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Theory of Everything"), "T")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Andor"), "A")
        // A title that is only the article keeps its own letter.
        XCTAssertEqual(TVAlphabetIndex.letter(for: "The"), "T")
    }

    func test_accents_foldToTheirLetter() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Élite"), "E")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Ødegaard"), "O")
    }

    func test_digits_punctuation_nonLatin_andEmpty_goUnderHash() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "12 Angry Men"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "(500) Days of Summer"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "千と千尋の神隠し"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: ""), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "   "), "#")
    }

    func test_firstItemIDs_takesTheFirstInListOrder_perLetter() {
        let items = [(id: "1", name: "12 Angry Men"), (id: "2", name: "Andor"), (id: "3", name: "Arrival"), (id: "4", name: "The Boy")]
        let index = TVAlphabetIndex.firstItemIDs(items)
        XCTAssertEqual(index["#"], "1")
        XCTAssertEqual(index["A"], "2")
        XCTAssertEqual(index["B"], "4")
        XCTAssertNil(index["C"])
    }

    /// Descending order: the first in list order is still the jump target.
    func test_firstItemIDs_inDescendingOrder() {
        let items = [(id: "3", name: "Arrival"), (id: "2", name: "Andor")]
        XCTAssertEqual(TVAlphabetIndex.firstItemIDs(items)["A"], "3")
    }

    func test_everyTitleIsReachable() {
        let names = ["", "7", "Élite", "The", "the matrix", "zebra", "千"]
        for name in names {
            XCTAssertTrue(TVAlphabetIndex.letters.contains(TVAlphabetIndex.letter(for: name)), "\"\(name)\" has no letter on the bar")
        }
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVAlphabetIndexTests`. Expected: build fails, "cannot find 'TVAlphabetIndex' in scope".

- [ ] **Step 3: Implement the index**

`DionysusTV/Browse/TVAlphabetIndex.swift`:

```swift
import Foundation

/// The grid's alphabet bar: which letter a title sits under, and the first
/// item for each letter.
///
/// The grid is ordered by Jellyfin's sort name, which drops a leading
/// article, so the letter does the same. Anything that isn't A–Z once
/// accents are folded (digits, punctuation, other scripts, an empty name)
/// goes under "#", so no title is left without a letter.
enum TVAlphabetIndex {
    static let letters: [Character] = ["#"] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private static let articles = ["the ", "a ", "an "]

    static func letter(for name: String) -> Character {
        var title = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let article = articles.first(where: title.hasPrefix) {
            let rest = title.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { title = rest }
        }
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
        // "Ø" doesn't decompose; map the few such letters by hand.
        let first = folded.first.map { Self.stroked[$0] ?? $0 }
        guard let first, first.isASCII, first.isLetter else { return "#" }
        return first
    }

    private static let stroked: [Character: Character] = ["Ø": "O", "Ł": "L", "Đ": "D", "Æ": "A", "Œ": "O"]

    /// The first item, in list order, under each letter.
    static func firstItemIDs(_ items: [(id: String, name: String)]) -> [Character: String] {
        var index: [Character: String] = [:]
        for item in items {
            let letter = letter(for: item.name)
            if index[letter] == nil { index[letter] = item.id }
        }
        return index
    }
}
```

Run the unit tests. Expected: PASS.

- [ ] **Step 4: Write the failing journeys**

Add to `A11yID.TV.Library`:

```swift
            static let count = "tv.library.count"
            static let sort = "tv.library.sort"
            static func filter(_ facet: String) -> String { "tv.library.filter.\(facet)" }
            static func letter(_ letter: String) -> String { "tv.library.letter.\(letter)" }
            static let resetFilters = "tv.library.resetFilters"
            static let retry = "tv.library.retry"
```

`DionysusTVUITests/CollectionGridJourneyTests.swift`:

```swift
import XCTest

final class CollectionGridJourneyTests: TVUITestCase {
    func test_grid_showsItsCount_pills_andSixColumns() {
        let app = launchAtHome()
        _ = openMovies(app)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Library.count].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Library.sort].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Library.filter("genre")].exists)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile."))
        let firstRowY = tiles.element(boundBy: 0).frame.minY
        let inFirstRow = (0..<tiles.count).filter { abs(tiles.element(boundBy: $0).frame.minY - firstRowY) < 30 }.count
        XCTAssertEqual(inFirstRow, 6, "Six posters to a row")
    }

    func test_tile_opensItsDetailPage_andMenuReturnsToIt() {
        let app = launchAtHome()
        _ = openMovies(app)
        press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let tile = app.buttons[focused.identifier]
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(tile))
    }

    /// The bar jumps focus to the first title under a letter. Right from the
    /// last column reaches it.
    func test_alphabetBar_jumpsToTheFirstTitleForALetter() {
        let app = launchAtHome()
        _ = openMovies(app)
        press(.right, times: 6)
        let onBar = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.letter.")).firstMatch
        XCTAssertTrue(onBar.waitForExistence(timeout: 5), "Right from the last column lands on the bar")
        // Down to the last enabled letter, then Select.
        let letters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND isEnabled == true", "tv.library.letter."))
        let last = letters.element(boundBy: letters.count - 1)
        pressDown(until: last)
        press(.select)
        let focusedTile = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focusedTile.waitForExistence(timeout: 5), "Choosing a letter moves focus into the grid")
        XCTAssertNotEqual(focusedTile.identifier, firstLibraryTile(app).identifier, "…to that letter's first title, not the grid's first")
    }

    func test_alphabetBar_isHidden_whenNotSortedByTitle() {
        let app = launchAtHome()
        _ = openMovies(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.sort]))
        press(.select)
        // The menu's second row: Date Added.
        press(.down)
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)) || firstLibraryTile(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Library.letter("A")].exists)
    }

    /// Filtering to nothing can't happen through the pills (they cascade),
    /// but a filtered grid must narrow, and Reset must widen it again.
    func test_genreFilter_narrowsTheGrid() {
        let app = launchAtHome()
        _ = openMovies(app)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile."))
        let all = tiles.count
        press(.up)
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.filter("genre")]))
        press(.select)
        press(.down)
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { tiles.count > 0 && tiles.count < all })
    }

    /// Review Focus 1.
    func test_watchedOnDetail_showsOnTheGridTileAfterBack() {
        let app = launchAtHome()
        _ = openMovies(app)
        let tile = firstLibraryTile(app)
        let tileID = tile.identifier
        press(.down, times: 2)
        let lower = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(lower.waitForExistence(timeout: 5))
        let lowerID = lower.identifier
        // The tile's value, not its label: labels are localized.
        let valueBefore = app.buttons[lowerID].value as? String
        openDetailFromFocusedTile(app)
        let watched = app.buttons[A11yID.TV.Detail.watched]
        let before = watched.label
        for _ in 0..<3 where !watched.hasFocus { press(.right) }
        press(.select)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: watched)], timeout: 5), .completed)
        press(.menu)
        let back = app.buttons[lowerID]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(poll(timeout: 10) { (back.value as? String) != valueBefore }, "The tile beneath shows the new watched state")
        let top = app.buttons[tileID]
        XCTAssertTrue(!top.exists || top.frame.minY < 0, "The grid stayed where it was")
    }

    func test_failedLibrary_showsRetry() {
        let app = launchAtHome(scenario: "failingLibrary")
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)])
        press(.select)
        let retry = app.buttons[A11yID.TV.Library.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(retry))
    }
}
```

The watched journey compares the tile's accessibility value before and after, which the grid's tiles set with `.accessibilityValue(item.isPlayed ? "watched" : "unwatched")`. Add a `failingLibrary` scenario to the stub: `GET /Users/{id}/Items` with `ParentId=lib-movies` answers 500.

- [ ] **Step 5: Run them and see them fail**

Run: tvOS UI with `-only-testing:DionysusTVUITests/CollectionGridJourneyTests`. Expected: FAIL on the first assertion (`tv.library.count` not found).

- [ ] **Step 6: Implement the grid**

`DionysusTV/Browse/TVCollectionGridView.swift`:

```swift
import SwiftUI

/// A library's page and a See All grid (prototype screen 9), on the shared
/// `CollectionGridViewModel`: a title and count, a sort pill, the five
/// cascading filter pills, six columns of posters, and an alphabet bar down
/// the right edge while sorted by title.
struct TVCollectionGridView: View {
    let title: String
    let titleIdentifier: String
    let viewModel: CollectionGridViewModel
    @Binding var rememberedItemID: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @FocusState private var focus: String?

    private var items: [MediaItem] { viewModel.filteredItems }
    private var showsAlphabet: Bool { viewModel.sortField == .title && !items.isEmpty }
    private var letterTargets: [Character: String] {
        TVAlphabetIndex.firstItemIDs(items.map { (id: $0.id, name: $0.name) })
    }

    var body: some View {
        TVPageScaffold {
            // Drawn whenever there are items, whatever the load state: a
            // refresh on the way back from a detail page must not blank the
            // grid and lose its place.
            if !viewModel.items.isEmpty {
                grid
            } else if case .failed(let message) = viewModel.loadState {
                TVPageMessage(title: String(localized: "Couldn't Load \(title)"), message: message, actionTitle: "Try Again", actionIdentifier: A11yID.TV.Library.retry) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.loadState == .loaded {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                .padding(.top, 60)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await viewModel.loadIfNeeded() }
        // Back on show: a detail page above may have changed a tile's
        // watched or favourite state.
        .onChange(of: isOnShow) { _, onShow in
            if onShow { Task { await viewModel.load() } }
        }
        .tvClaimsFocus($focus, ids: items.map(\.id), remembered: $rememberedItemID)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text(verbatim: title).font(.title2.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier(titleIdentifier)
            Text("\(items.count) items").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier(A11yID.TV.Library.count)
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        header
                        pills
                        if items.isEmpty {
                            // Unreachable through the pills, which cascade;
                            // reachable when the server's data changes under
                            // an active filter.
                            Button("Reset Filters") { viewModel.resetFilters() }
                                .accessibilityIdentifier(A11yID.TV.Library.resetFilters)
                        }
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(TVTileMetrics.gridPoster.width), spacing: 44, alignment: .leading), count: 6),
                            alignment: .leading, spacing: 60
                        ) {
                            ForEach(items) { item in
                                TVPosterTile(item: item, size: TVTileMetrics.gridPoster, caption: .onFocus, identifier: A11yID.TV.Library.tile(item.id)) {
                                    open(.assetDetail(itemID: item.id, preloadedItem: item))
                                }
                                .focused($focus, equals: item.id)
                                .accessibilityValue(item.isPlayed ? "watched" : "unwatched")
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 160)
                }
                .scrollClipDisabled()
                .focusSection()

                if showsAlphabet {
                    alphabetBar(proxy)
                }
            }
        }
    }

    private var pills: some View {
        HStack(spacing: 16) {
            Menu {
                Picker("Sort By", selection: Binding(get: { viewModel.sortField }, set: { field in Task { await viewModel.setSortField(field) } })) {
                    Text("Title").tag(CollectionSortField.title)
                    Text("Date Added").tag(CollectionSortField.dateAdded)
                    Text("Release Date").tag(CollectionSortField.releaseDate)
                }
                Picker("Order", selection: Binding(get: { viewModel.sortOrder }, set: { order in Task { await viewModel.setSortOrder(order) } })) {
                    Text("Ascending").tag(CollectionSortOrder.ascending)
                    Text("Descending").tag(CollectionSortOrder.descending)
                }
            } label: {
                Label(sortTitle, systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier(A11yID.TV.Library.sort)

            Divider().frame(height: 40)

            filterPill("genre", title: String(localized: "Genre"), all: String(localized: "All Genres"),
                       options: viewModel.availableGenres, selection: viewModel.selectedGenre, display: { $0 }, set: viewModel.setGenreFilter)
            filterPill("studio", title: studioTitle, all: studioAllTitle,
                       options: viewModel.availableStudios, selection: viewModel.selectedStudio, display: { $0 }, set: viewModel.setStudioFilter)
            // "1990s": a formatted year, not translated.
            filterPill("decade", title: String(localized: "Decade"), all: String(localized: "All Decades"),
                       options: viewModel.availableDecades, selection: viewModel.selectedDecade, display: { "\($0)s" }, set: viewModel.setDecadeFilter)
            filterPill("watched", title: String(localized: "Watched"), all: String(localized: "All Items"),
                       options: viewModel.availableWatchStatuses, selection: viewModel.selectedWatchStatus,
                       display: { $0 == .watched ? String(localized: "Watched") : String(localized: "Unwatched") }, set: viewModel.setWatchStatusFilter)
            filterPill("favorites", title: String(localized: "Favorites"), all: String(localized: "All Items"),
                       options: viewModel.availableFavoriteStatuses, selection: viewModel.selectedFavoriteStatus,
                       display: { $0 == .favorite ? String(localized: "Favorites") : String(localized: "Non-Favorites") }, set: viewModel.setFavoriteStatusFilter)
        }
        .focusSection()
    }

    private var sortTitle: String {
        switch viewModel.sortField {
        case .title: String(localized: "Title")
        case .dateAdded: String(localized: "Date Added")
        case .releaseDate: String(localized: "Release Date")
        }
    }

    /// Jellyfin has no Network field: a show's network is in Studios.
    private var isSeries: Bool { viewModel.query.includeItemTypes.contains("Series") }
    private var studioTitle: String { isSeries ? String(localized: "Network") : String(localized: "Studio") }
    private var studioAllTitle: String { isSeries ? String(localized: "All Networks") : String(localized: "All Studios") }

    /// A pill is drawn only while it has something to offer, as on iOS. The
    /// options come from the view model, which applies every other active
    /// facet first, so no choice here leaves the grid empty.
    @ViewBuilder
    private func filterPill<Option: Hashable>(
        _ facet: String, title: String, all: String, options: [Option], selection: Option?,
        display: @escaping (Option) -> String, set: @escaping (Option?) -> Void
    ) -> some View {
        if !options.isEmpty {
            Menu {
                Button { set(nil) } label: { selection == nil ? Label(all, systemImage: "checkmark") : Label(all, systemImage: "") }
                ForEach(options, id: \.self) { option in
                    Button { set(option) } label: {
                        option == selection ? Label(display(option), systemImage: "checkmark") : Label(display(option), systemImage: "")
                    }
                }
            } label: {
                Text(verbatim: selection.map(display) ?? title)
            }
            .accessibilityIdentifier(A11yID.TV.Library.filter(facet))
        }
    }

    /// "#" and A–Z; a letter with no titles is dimmed and can't take focus.
    /// Choosing one scrolls its first title into view, then moves focus to
    /// it: the grid is lazy, so the tile has to be built before it can be
    /// focused.
    private func alphabetBar(_ proxy: ScrollViewProxy) -> some View {
        let targets = letterTargets
        return VStack(spacing: 0) {
            ForEach(TVAlphabetIndex.letters, id: \.self) { letter in
                Button {
                    guard let id = targets[letter] else { return }
                    proxy.scrollTo(id, anchor: .top)
                    Task { @MainActor in
                        for _ in 0..<10 {
                            try? await Task.sleep(for: .milliseconds(50))
                            focus = id
                            if focus == id { return }
                        }
                    }
                } label: {
                    Text(verbatim: String(letter)).font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 28)
                }
                .buttonStyle(TVAlphabetKeyStyle())
                .disabled(targets[letter] == nil)
                .accessibilityIdentifier(A11yID.TV.Library.letter(String(letter)))
            }
        }
        .padding(.top, 190)
        .padding(.trailing, 56)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Jump to letter"))
    }
}

/// A letter of the alphabet bar: small, so the system button's padding and
/// lift would overlap its neighbours.
private struct TVAlphabetKeyStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(isEnabled ? 0.85 : 0.25))
            .background(isFocused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(isFocused ? 1.25 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
```

`String(localized: "\(items.count) items")` needs a plural variant in the catalog ("1 item"); add it when syncing strings. If `set: viewModel.setGenreFilter` doesn't type-check as `(String?) -> Void`, wrap each in a closure.

Delete `DionysusTV/Browse/TVLibraryGridView.swift`. In `TVMainView`, replace both `TVLibraryGridView(…)` call sites with `TVCollectionGridView(title:titleIdentifier:viewModel:rememberedItemID:)` (same arguments) and remove the "Task 7 replaces this stopgap" comment.

- [ ] **Step 7: Run everything**

Run `xcodegen generate`, then tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: PASS. `SidebarJourneyTests.test_emptyLibrary_leavesFocusOnItsRow` should still pass: an empty library has no focusable item, so the shell's three-second fallback still applies. If the alphabet bar's 27 letters don't fit 830pt of height on the Simulator, reduce the key height from 28, not the letter count.

- [ ] **Step 8: Docs, commit, PR**

CLAUDE.md's tvOS section: one paragraph on the grid (six columns, pills only while they have options, the alphabet bar only when sorted by title, letters from `TVAlphabetIndex` with articles skipped and "#" for everything not A–Z, a letter scrolls before it focuses because the grid is lazy, the grid stays drawn through a refresh). TESTING.md: `CollectionGridJourneyTests`, `TVAlphabetIndexTests`, the `failingLibrary` scenario. Remove the "empty or failed tvOS library page shows only its title" line from memory `open-issues-and-follow-ups`. Sync strings. After sign-off:

```bash
git add -u DionysusTV DionysusTVUITests
git add DionysusTV/Browse/TVAlphabetIndex.swift DionysusTV/Browse/TVCollectionGridView.swift DionysusTVTests/TVAlphabetIndexTests.swift DionysusTVUITests/CollectionGridJourneyTests.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md
git commit -m "Add the Apple TV collection grid, with filters and an alphabet bar"
```

Open PR 3; merge with `--merge` once checks pass.

---

## PR 4 — Home

### Task 8: The hero and the rails

**Files:**
- Create: `DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift`, `DionysusTV/Browse/Home/TVHeroPager.swift`, `TVHeroPlayTarget.swift`, `TVHeroView.swift`, `TVHomeView.swift`
- Delete: `DionysusTV/Browse/TVBrowseLauncher.swift`
- Modify: `DionysusPlayer/Features/Home/HeroRailView.swift` (key moved out), `DionysusTV/Browse/TVMainView.swift`, `AccessibilityIdentifiers.swift`, `DionysusTVUITests/Support/TVShellJourney.swift`
- Test: `DionysusTVTests/TVHeroPagerTests.swift`, `DionysusTVTests/TVHeroPlayTargetTests.swift`, `DionysusTVUITests/HomeJourneyTests.swift`; `BrowseJourneyTests` is deleted (its one test is superseded)

**Interfaces:**
- Consumes: `HomeViewModel` (`heroItems`, `rails`, `libraries`, `loadState`, `loadIfNeeded()`, `load()`, `softRefresh()`, `hasMoreDynamicRails`, `loadMoreDynamicRails()`), `MediaCollectionRail` (`id`, `title`, `items`, `seeAllQuery`, `usesLandscapeTiles`), `tvOpenRoute`, `tvSelectLibrary`, `tvPageIsOnShow`, `UITestHarness.freezesAmbientMotion`.
- Produces:
  - `let heroAutoCarouselEnabledStorageKey = "heroAutoCarouselEnabled"` in `PlayerPreferenceKeys.swift` (moved, same value).
  - `struct TVHeroPager: Equatable { init(count: Int); private(set) var index: Int; private(set) var stoppedByHand: Bool; var canGoBack: Bool; var canGoForward: Bool; mutating func tick(); mutating func forward(); mutating func back(); mutating func heroLostFocus(); mutating func setCount(_:); static let interval: Duration = .seconds(5); static func timerRuns(count:autoCarousel:reduceMotion:motionFrozen:heroHasFocus:isOnShow:stoppedByHand:) -> Bool }`
  - `enum TVHeroPlayTarget { static func resolve(_ item: MediaItem, client: JellyfinAPIClient, userID: String) async -> String? }`
  - `TVHomeView(client:userID:viewModel:rememberedFocus:)`
  - `A11yID.TV.Main`: `heroPlay`, `heroInfo`, `heroTitle`, `heroDots`, `seeAll(_:)`, `library(_:)`, `retry`. `tile(_:)` stays.

- [ ] **Step 1: Write the failing unit tests**

`DionysusTVTests/TVHeroPagerTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVHeroPagerTests: XCTestCase {
    func test_tick_advances_andWrapsToTheStart() {
        var pager = TVHeroPager(count: 3)
        pager.tick()
        XCTAssertEqual(pager.index, 1)
        pager.tick()
        pager.tick()
        XCTAssertEqual(pager.index, 0)
    }

    /// By hand there is no wrap: Left on the first item must stay free to
    /// open the rail, and Right on the last stops.
    func test_byHand_stopsAtEitherEnd() {
        var pager = TVHeroPager(count: 2)
        XCTAssertFalse(pager.canGoBack)
        pager.back()
        XCTAssertEqual(pager.index, 0)
        pager.forward()
        XCTAssertEqual(pager.index, 1)
        XCTAssertFalse(pager.canGoForward)
        pager.forward()
        XCTAssertEqual(pager.index, 1)
        XCTAssertTrue(pager.canGoBack)
    }

    func test_aPressByHand_stopsTheTimerForThisVisit_andLeavingStartsItAgain() {
        var pager = TVHeroPager(count: 3)
        pager.forward()
        XCTAssertTrue(pager.stoppedByHand)
        pager.heroLostFocus()
        XCTAssertFalse(pager.stoppedByHand)
    }

    func test_timerRuns_onlyWhenEverythingAllowsIt() {
        func runs(count: Int = 3, auto: Bool = true, reduce: Bool = false, frozen: Bool = false, focus: Bool = true, onShow: Bool = true, stopped: Bool = false) -> Bool {
            TVHeroPager.timerRuns(count: count, autoCarousel: auto, reduceMotion: reduce, motionFrozen: frozen, heroHasFocus: focus, isOnShow: onShow, stoppedByHand: stopped)
        }
        XCTAssertTrue(runs())
        XCTAssertFalse(runs(count: 1), "One item has nowhere to go")
        XCTAssertFalse(runs(count: 0))
        XCTAssertFalse(runs(auto: false), "Auto Carousel is off")
        XCTAssertFalse(runs(reduce: true))
        XCTAssertFalse(runs(frozen: true), "The UI-test harness freezes ambient motion")
        XCTAssertFalse(runs(focus: false), "Only while the hero has focus")
        XCTAssertFalse(runs(onShow: false), "A hidden page runs no timer")
        XCTAssertFalse(runs(stopped: true))
    }

    /// A refresh can return fewer hero items than the index points at.
    func test_setCount_clampsTheIndex() {
        var pager = TVHeroPager(count: 5)
        pager.tick(); pager.tick(); pager.tick()
        pager.setCount(2)
        XCTAssertEqual(pager.index, 1)
        pager.setCount(0)
        XCTAssertEqual(pager.index, 0)
        pager.tick()
        XCTAssertEqual(pager.index, 0, "Nothing to advance through")
    }
}
```

`DionysusTVTests/TVHeroPlayTargetTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVHeroPlayTargetTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func client() -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession())
    }

    func test_aMovie_playsItself_withNoRequest() async {
        MockURLProtocol.requestHandler = { request in
            XCTFail("No request expected, got \(request.url?.path ?? "")")
            return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }
        let movie = MediaItem(dto: BaseItemDto(id: "m1", name: "Arrival", type: .movie), images: images)
        let target = await TVHeroPlayTarget.resolve(movie, client: client(), userID: "u")
        XCTAssertEqual(target, "m1")
    }

    /// The spike's bug: a series in the hero needs its Play to resolve an
    /// episode, since a series id itself doesn't play.
    func test_aSeries_playsItsNextUpEpisode() async {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Shows/NextUp")
            let episode = BaseItemDto(id: "e3", name: "Alone in the Night", type: .episode)
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [episode], totalRecordCount: 1))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertEqual(target, "e3")
    }

    func test_aSeriesNeverStarted_playsItsFirstEpisode() async {
        MockURLProtocol.requestHandler = { request in
            let items = request.url?.path == "/Shows/NextUp" ? [] : [BaseItemDto(id: "e1", name: "Earthfall", type: .episode)]
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertEqual(target, "e1")
    }

    func test_aSeriesWithNoEpisodes_hasNothingToPlay() async {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertNil(target)
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVHeroPagerTests -only-testing:DionysusTVTests/TVHeroPlayTargetTests`. Expected: build fails, "cannot find 'TVHeroPager' in scope".

- [ ] **Step 3: Implement the pure types and move the key**

`DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift`:

```swift
import Foundation

/// `UserDefaults` keys for preferences both apps read. They lived beside the
/// iOS views that first used them, which the Apple TV target doesn't compile.

/// Whether Home's hero advances by itself. On by default.
let heroAutoCarouselEnabledStorageKey = "heroAutoCarouselEnabled"
```

Delete the same `let` from the bottom of `DionysusPlayer/Features/Home/HeroRailView.swift`, moving its doc comment's substance into the new file if it says more than the line above.

`DionysusTV/Browse/Home/TVHeroPager.swift`:

```swift
import Foundation

/// Which hero item is on show, and when the timer may move it.
///
/// The timer wraps; a press by hand doesn't, so Left on the first item stays
/// free to open the rail. A press by hand also stops the timer until focus
/// has left the hero and come back: someone paging through is reading.
struct TVHeroPager: Equatable {
    /// iOS's `HeroRailView.autoAdvanceInterval`.
    static let interval: Duration = .seconds(5)

    private(set) var index = 0
    private(set) var stoppedByHand = false
    private var count: Int

    init(count: Int) { self.count = max(0, count) }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < count - 1 }

    mutating func tick() {
        guard count > 1 else { return }
        index = (index + 1) % count
    }

    mutating func forward() {
        stoppedByHand = true
        if canGoForward { index += 1 }
    }

    mutating func back() {
        stoppedByHand = true
        if canGoBack { index -= 1 }
    }

    mutating func heroLostFocus() { stoppedByHand = false }

    mutating func setCount(_ newCount: Int) {
        count = max(0, newCount)
        index = min(index, max(0, count - 1))
    }

    static func timerRuns(
        count: Int, autoCarousel: Bool, reduceMotion: Bool, motionFrozen: Bool,
        heroHasFocus: Bool, isOnShow: Bool, stoppedByHand: Bool
    ) -> Bool {
        count > 1 && autoCarousel && !reduceMotion && !motionFrozen && heroHasFocus && isOnShow && !stoppedByHand
    }
}
```

`DionysusTV/Browse/Home/TVHeroPlayTarget.swift`:

```swift
import Foundation

/// What the hero's Play starts. A movie or an episode plays itself; a series
/// id doesn't play, so its next episode is resolved the way the show page
/// resolves it (`AssetDetailViewModel.resolveShowPlaybackEpisode`): NextUp,
/// which returns an in-progress episode or the next unwatched one, falling
/// back to the first episode for a show never started.
enum TVHeroPlayTarget {
    static func resolve(_ item: MediaItem, client: JellyfinAPIClient, userID: String) async -> String? {
        guard item.kind == .series else { return item.id }
        if let next = try? await client.nextUp(userID: userID, seriesID: item.id).items.first {
            return next.id
        }
        return try? await client.episodes(seriesID: item.id, userID: userID).items.first?.id
    }
}
```

Run the unit tests on tvOS, and build iOS (`xcodebuild build … -scheme DionysusPlayer`) to confirm the moved key still resolves. Expected: PASS, BUILD SUCCEEDED.

- [ ] **Step 4: Write the failing journeys**

Add to `A11yID.TV.Main`:

```swift
            static let heroPlay = "tv.main.hero.play"
            static let heroInfo = "tv.main.hero.info"
            static let heroTitle = "tv.main.hero.title"
            static let heroDots = "tv.main.hero.dots"
            static func seeAll(_ title: String) -> String { "tv.main.seeAll.\(title)" }
            static func library(_ libraryID: String) -> String { "tv.main.library.\(libraryID)" }
            static let retry = "tv.main.retry"
```

In `TVShellJourney.swift`, replace `launchAtHome` and `openRailFromHome`:

```swift
    /// Signed in, on Home, with focus on the hero's Play.
    func launchAtHome(scenario: String = "standard") -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        let play = app.buttons[A11yID.TV.Main.heroPlay]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        return app
    }

    /// From the hero, Down to Continue Watching's first tile.
    @discardableResult
    func focusFirstRailTile(_ app: XCUIApplication) -> XCUIElement {
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        press(.down)
        XCTAssertTrue(waitForFocus(tile))
        return tile
    }

    /// Left from the hero's first item opens the rail on Home's row.
    func openRailFromHome(_ app: XCUIApplication) {
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
    }
```

Every existing journey that relied on `launchAtHome` leaving focus on the first rail tile (`DetailJourneyTests`, `ShowDetailJourneyTests`, `PlayerJourneyTests`, the renamed `PlayerReturnJourneyTests`, `SidebarJourneyTests.test_leftFromALowerRow…` and `test_choosingHome_fromALibrary…`) gains a `focusFirstRailTile(app)` call after launch where it then selects or moves from that tile; journeys that go straight to the rail (`openRailFromHome`, `openMovies`) need no change. `test_choosingHome_fromALibrary_focusesItsFirstTile` asserts focus on `heroPlay` and is renamed `…focusesTheHero`.

`DionysusTVUITests/HomeJourneyTests.swift`:

```swift
import XCTest

final class HomeJourneyTests: TVUITestCase {
    func test_home_opensOnTheHero_withRailsBelow() {
        let app = launchAtHome()
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroInfo].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Main.heroTitle].exists)
        focusFirstRailTile(app)
    }

    func test_heroPlay_startsPlayback_andMenuReturnsToIt() {
        let app = launchAtHome()
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].exists)
    }

    func test_moreInfo_opensTheDetailPage() {
        let app = launchAtHome()
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]))
    }

    /// Right from More Info pages the hero forward; Left from Play pages it
    /// back; Left on the first item opens the rail.
    func test_hero_pagesByHand_andLeftOnTheFirstItemOpensTheRail() {
        let app = launchAtHome()
        let title = app.descendants(matching: .any)[A11yID.TV.Main.heroTitle]
        let first = title.label
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]))
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { title.label != first }, "Right from More Info shows the next item")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]) || waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]), "Focus stays in the hero")

        for _ in 0..<2 where !app.buttons[A11yID.TV.Main.heroPlay].hasFocus { press(.left) }
        press(.left)
        XCTAssertTrue(poll(timeout: 5) { title.label == first }, "Left from Play shows the previous item")
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "…without opening the rail")

        for _ in 0..<2 where !app.buttons[A11yID.TV.Main.heroPlay].hasFocus { press(.left) }
        press(.left)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]), "Left on the first item opens the rail")
    }

    /// The harness freezes ambient motion, so the hero must not move by
    /// itself here; the timer's rules are pinned by `TVHeroPagerTests`.
    func test_hero_staysPut_underTheHarness() {
        let app = launchAtHome()
        let title = app.descendants(matching: .any)[A11yID.TV.Main.heroTitle]
        let first = title.label
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        XCTAssertEqual(title.label, first)
    }

    func test_seeAll_opensAGrid_andMenuReturnsToIt() {
        let app = launchAtHome()
        let seeAll = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.main.seeAll.")).firstMatch
        for _ in 0..<6 where !seeAll.exists { press(.down) }
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        for _ in 0..<20 where !seeAll.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(seeAll))
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)), "See All opens a grid, with the rail still on Home's row")
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]))
        press(.menu)
        XCTAssertTrue(waitForFocus(seeAll))
    }

    /// A Libraries tile switches to the library's own page; it doesn't push.
    func test_librariesRail_switchesToTheLibrarysPage() {
        let app = launchAtHome()
        let library = app.buttons[A11yID.TV.Main.library(UITestFixtureIdentity.moviesLibraryID)]
        for _ in 0..<12 where !library.exists { press(.down) }
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        for _ in 0..<4 where !library.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(library))
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)))
        press(.menu)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)]),
                      "Menu opens the rail on the library's row: it's a top-level page, not a pushed one")
    }

    func test_failedHome_showsRetry() {
        let app = launch(scenario: "failingHome", seedSession: true)
        let retry = app.buttons[A11yID.TV.Main.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFocus(retry))
    }
}
```

Add a `failingHome` scenario to the stub: the requests Home's first load makes (`/Users/{id}/Views`, `/Items/Resume`, `/Shows/NextUp`, `/Items/Latest`, and the hero's `/Users/{id}/Items` with `SortBy=Random`) answer 500; `/Users/{id}/Views` must still succeed for the sidebar if the sidebar would otherwise mask the result (check `TVSidebarModel` uses the same endpoint, and if so fail only the other four). Delete `DionysusTVUITests/BrowseJourneyTests.swift`.

- [ ] **Step 5: Run them and see them fail**

Run: tvOS UI with `-only-testing:DionysusTVUITests/HomeJourneyTests`. Expected: FAIL in `launchAtHome` (no `tv.main.hero.play`).

- [ ] **Step 6: Implement Home**

`DionysusTV/Browse/Home/TVHeroView.swift`:

```swift
import SwiftUI

/// Home's hero (prototype screen 5): the current item's logo, a metadata
/// line, two lines of overview, Play and More Info, and page dots. Its
/// backdrop is the page's background, drawn by `TVHomeView` behind the rail.
///
/// Paging by hand uses two invisible focus guards beside the buttons: a
/// guard that takes focus turns the page and hands focus back. The left one
/// can't take focus on the first item, so Left there reaches the rail.
struct TVHeroView: View {
    let item: MediaItem
    let count: Int
    @Binding var pager: TVHeroPager
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let moreInfo: () -> Void

    static let playFocus = "hero.play"
    static let infoFocus = "hero.info"
    private static let backGuard = "hero.guard.back"
    private static let forwardGuard = "hero.guard.forward"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVDetailHeader(item: item, showsBadges: false)
                .accessibilityIdentifier(A11yID.TV.Main.heroTitle)
            if let overview = item.overview, item.hasDescription {
                Text(verbatim: overview).lineLimit(2).frame(width: 820, alignment: .leading).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 26) {
                pageGuard(Self.backGuard, enabled: pager.canGoBack) {
                    pager.back()
                    focus.wrappedValue = Self.playFocus
                }
                Button(action: play) { Label("Play", systemImage: "play.fill") }
                    .focused(focus, equals: Self.playFocus)
                    .accessibilityIdentifier(A11yID.TV.Main.heroPlay)
                Button(action: moreInfo) { Label("More Info", systemImage: "info.circle") }
                    .focused(focus, equals: Self.infoFocus)
                    .accessibilityIdentifier(A11yID.TV.Main.heroInfo)
                pageGuard(Self.forwardGuard, enabled: pager.canGoForward) {
                    pager.forward()
                    focus.wrappedValue = Self.infoFocus
                }
                Spacer()
                dots
            }
            .padding(.top, 14)
            .padding(.trailing, 140)
        }
        .focusSection()
    }

    /// One point wide and unseen: it exists to catch a Left or Right that
    /// would otherwise leave the hero.
    private func pageGuard(_ id: String, enabled: Bool, turn: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 1, height: 60)
            .focusable(enabled)
            .focused(focus, equals: id)
            .onChange(of: focus.wrappedValue) { _, now in
                if now == id { turn() }
            }
            .accessibilityHidden(true)
    }

    private var dots: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == pager.index ? 1 : 0.4))
                    .frame(width: index == pager.index ? 44 : 12, height: 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Item \(pager.index + 1) of \(count)"))
        .accessibilityIdentifier(A11yID.TV.Main.heroDots)
    }
}
```

`TVDetailHeader` carries `A11yID.TV.Detail.title` on its logo; give `TVDetailHeader` a `titleIdentifier: String = A11yID.TV.Detail.title` parameter and pass `A11yID.TV.Main.heroTitle` here, instead of the outer `.accessibilityIdentifier` above (an identifier on a container can overwrite its descendants').

`DionysusTV/Browse/Home/TVHomeView.swift`:

```swift
import SwiftUI

/// Home (prototype screen 5): the hero over a full-bleed backdrop, then the
/// rails in the iOS order, on the shared `HomeViewModel`.
struct TVHomeView: View {
    let client: JellyfinAPIClient
    let userID: String
    /// Owned by the shell, so Home's data outlives its views.
    let viewModel: HomeViewModel
    @Binding var rememberedFocus: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvSelectLibrary) private var selectLibrary
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarousel = true
    @FocusState private var focus: String?
    @State private var pager = TVHeroPager(count: 0)

    private var heroItem: MediaItem? {
        viewModel.heroItems.indices.contains(pager.index) ? viewModel.heroItems[pager.index] : viewModel.heroItems.first
    }

    private var libraries: [MediaItem] { viewModel.libraries.filter { !$0.isAudioLibrary } }
    private var heroHasFocus: Bool { focus?.hasPrefix("hero.") ?? false }

    private var timerRuns: Bool {
        TVHeroPager.timerRuns(
            count: viewModel.heroItems.count, autoCarousel: autoCarousel, reduceMotion: reduceMotion,
            motionFrozen: UITestHarness.freezesAmbientMotion, heroHasFocus: heroHasFocus,
            isOnShow: isOnShow, stoppedByHand: pager.stoppedByHand
        )
    }

    private static func tileFocus(rail: UUID, item: String) -> String { "rail.\(rail.uuidString).\(item)" }

    /// Every focusable item in order; the hero's Play is the default.
    private var focusIDs: [String] {
        (heroItem == nil ? [] : [TVHeroView.playFocus, TVHeroView.infoFocus])
            + viewModel.rails.flatMap { rail in
                rail.items.map { Self.tileFocus(rail: rail.id, item: $0.id) } + (rail.seeAllQuery == nil ? [] : ["seeall.\(rail.id.uuidString)"])
            }
            + libraries.map { "library.\($0.id)" }
    }

    var body: some View {
        TVPageScaffold(background: { background }) {
            if heroItem != nil || !viewModel.rails.isEmpty {
                content
            } else if case .failed(let message) = viewModel.loadState {
                TVPageMessage(title: String(localized: "Couldn't Load Home"), message: message, actionTitle: "Try Again", actionIdentifier: A11yID.TV.Main.retry) {
                    Task { await viewModel.load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await viewModel.loadIfNeeded() }
        .onChange(of: viewModel.heroItems.count, initial: true) { _, count in pager.setCount(count) }
        .onChange(of: heroHasFocus) { _, has in
            if !has { pager.heroLostFocus() }
        }
        // Back on show after a detail page or a See All grid: progress and
        // watched state may have changed.
        .onChange(of: isOnShow) { _, onShow in
            if onShow { Task { await viewModel.softRefresh() } }
        }
        // Restarted whenever the item changes, so each gets a full interval.
        .task(id: "\(timerRuns)-\(pager.index)") {
            guard timerRuns else { return }
            try? await Task.sleep(for: TVHeroPager.interval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { pager.tick() }
        }
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
    }

    @ViewBuilder
    private var background: some View {
        if let heroItem {
            TVDetailBackdrop(item: heroItem)
                .id(heroItem.id)
                .transition(.opacity)
        }
    }

    private var content: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if let heroItem {
                    TVHeroView(item: heroItem, count: viewModel.heroItems.count, pager: $pager, focus: $focus) {
                        playHero(heroItem)
                    } moreInfo: {
                        open(.assetDetail(itemID: heroItem.id, preloadedItem: heroItem))
                    }
                    // The hero fills the first screen; the first rail's
                    // title shows at its foot.
                    .frame(height: 860, alignment: .bottomLeading)
                }
                ForEach(viewModel.rails) { rail in
                    railView(rail)
                }
                if viewModel.hasMoreDynamicRails {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await viewModel.loadMoreDynamicRails() }
                }
                if !libraries.isEmpty {
                    librariesRail
                }
            }
            .padding(.bottom, 200)
        }
        .scrollClipDisabled()
    }

    private func railView(_ rail: MediaCollectionRail) -> some View {
        TVRail(title: rail.title) {
            ForEach(rail.items) { item in
                Group {
                    if rail.usesLandscapeTiles {
                        TVLandscapeTile(item: item, title: item.railTitle, subtitle: item.railSubtitle, identifier: A11yID.TV.Main.tile(item.id)) {
                            open(.assetDetail(itemID: item.id, preloadedItem: item))
                        }
                    } else {
                        TVPosterTile(item: item, identifier: A11yID.TV.Main.tile(item.id)) {
                            open(.assetDetail(itemID: item.id, preloadedItem: item))
                        }
                    }
                }
                .focused($focus, equals: Self.tileFocus(rail: rail.id, item: item.id))
            }
            if let query = rail.seeAllQuery {
                Button { open(.collection(query)) } label: {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.right").font(.system(size: 64)).accessibilityHidden(true)
                        Text("See All").font(.callout.weight(.semibold))
                    }
                    .frame(width: TVTileMetrics.poster.width, height: rail.usesLandscapeTiles ? TVTileMetrics.landscape.height : TVTileMetrics.poster.height)
                    .background(.white.opacity(0.1))
                }
                .buttonStyle(.card)
                .focused($focus, equals: "seeall.\(rail.id.uuidString)")
                .accessibilityIdentifier(A11yID.TV.Main.seeAll(rail.title))
            }
        }
    }

    /// Each tile switches to the library's own page.
    private var librariesRail: some View {
        TVRail(title: String(localized: "Libraries")) {
            ForEach(libraries) { library in
                Button { selectLibrary(library.id) } label: {
                    AsyncRemoteImage(url: library.primaryImageURL, placeholderSystemImage: TVSidebarLayout.systemImage(forCollectionType: library.collectionType))
                        .frame(width: TVTileMetrics.episode.width, height: TVTileMetrics.episode.height)
                        .overlay {
                            Text(verbatim: library.name)
                                .font(.system(size: 44, weight: .bold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(red: 20 / 255, green: 4 / 255, blue: 14 / 255).opacity(0.55))
                        }
                }
                .buttonStyle(.card)
                .focused($focus, equals: "library.\(library.id)")
                .accessibilityLabel(library.name)
                .accessibilityIdentifier(A11yID.TV.Main.library(library.id))
            }
        }
    }

    private func playHero(_ item: MediaItem) {
        Task { @MainActor in
            guard let target = await TVHeroPlayTarget.resolve(item, client: client, userID: userID) else {
                // Nothing to play (a series with no episodes): its page says so.
                open(.assetDetail(itemID: item.id, preloadedItem: item))
                return
            }
            TVPlayerPresenter.present(PlaybackRequest(itemID: target), client: client, userID: userID) { _ in
                Task { await viewModel.softRefresh() }
            }
        }
    }
}
```

In `TVMainView`: the `default:` branch of `page` becomes `TVHomeView(client: client, userID: userID, viewModel: home, rememberedFocus: $rememberedHomeTile)`. Update `TVPageScaffold`'s doc comment ("M3's Home brings its own hero" → "Home and detail pages bring their own backdrop"). Delete `DionysusTV/Browse/TVBrowseLauncher.swift`. Remove `A11yID.TV.Main.root` if nothing else uses it (`grep -rn "TV.Main.root"`).

If the focus guard's page turn fights `tvClaimsFocus` (which records the guard's id as remembered), have `TVHeroView` set focus back before the next run loop, and exclude ids with the `hero.guard.` prefix from what `TVHomeView` remembers by keeping them out of `focusIDs`, as above.

- [ ] **Step 7: Run everything**

Run `xcodegen generate`, then tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: PASS.

- [ ] **Step 8: Look at it**

Run the app on the Simulator against the LAN test server (memory `jellyfin-test-server`, `simulator-automation`) and check against prototype screen 5: the hero advances every five seconds while it has focus and stops when focus moves to a rail; Right from More Info and Left from Play turn the page; the backdrop cross-fades; a series in the hero plays an episode. Screenshot Home for the PR.

- [ ] **Step 9: Docs, commit, PR**

CLAUDE.md's tvOS section: Home is `TVHomeView` on `HomeViewModel`; the hero's timer rules are `TVHeroPager.timerRuns`; paging by hand uses focus guards and why Left on the first item is left alone; a series in the hero resolves an episode (`TVHeroPlayTarget`); a Libraries tile selects a page instead of pushing. TESTING.md: `HomeJourneyTests`, `launchAtHome` now lands on the hero, `focusFirstRailTile`, the `failingHome` scenario. Remove "tvOS Home doesn't retry a failed load" from memory `open-issues-and-follow-ups`. Sync strings. After sign-off:

```bash
git add -u DionysusTV DionysusTVUITests DionysusPlayer/Features/Home/HeroRailView.swift
git add DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift DionysusTV/Browse/Home DionysusTVTests/TVHeroPagerTests.swift DionysusTVTests/TVHeroPlayTargetTests.swift DionysusTVUITests/HomeJourneyTests.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md
git commit -m "Add the Apple TV Home screen, with its hero and rails"
```

Open PR 4; merge with `--merge` once checks pass.

---

## PR 5 — Search

### Task 9: Search results by type, and Recent Searches

**Files:**
- Create: `DionysusTV/Browse/TVSearchGrouping.swift`
- Modify: `DionysusTV/Browse/TVSearchView.swift`, `DionysusTV/Player/TVPlayerPresenter.swift` (delete `present(itemID:…)`), `AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests/TVSearchGroupingTests.swift`, `DionysusTVUITests/SearchJourneyTests.swift`

**Interfaces:**
- Consumes: `SearchViewModel` (`query`, `results`, `history`, `loadState`, `queryChanged()`, `recordSelection(_:)`, `clearHistory()`, `imageURL(for:preferLandscape:)`, `loadImagesIfNeeded()`), `SearchResult` (`id`, `name`, `subtitle`, `kind`, `accessibilityDescription`), `TVRail`, `tvOpenRoute`.
- Produces:
  - `enum TVSearchGrouping { struct Section: Equatable, Identifiable { let id: String; let title: String; let results: [SearchResult] }; static func sections(_ results: [SearchResult]) -> [Section] }`
  - `A11yID.TV.Search`: `recent(_:)`, `clearRecent`, `noResults`, `section(_:)`. `result(_:)` stays.

- [ ] **Step 1: Write the failing unit tests**

`DionysusTVTests/TVSearchGroupingTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVSearchGroupingTests: XCTestCase {
    private func result(_ id: String, _ kind: BaseItemKind?) throws -> SearchResult {
        // `SearchResult` is built from a hint or decoded; decoding lets a
        // test set `kind` to nil, as old history entries have it.
        var json: [String: Any] = ["id": id, "name": id]
        if let kind { json["kind"] = kind.rawValue }
        return try JSONDecoder().decode(SearchResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_sections_comeInAFixedOrder_whateverOrderTheServerSent() throws {
        let results = [try result("e", .episode), try result("b", .boxSet), try result("m", .movie), try result("s", .series), try result("p", .playlist)]
        XCTAssertEqual(TVSearchGrouping.sections(results).map(\.id), ["movies", "shows", "episodes", "collections", "playlists"])
    }

    func test_withinASection_theServersOrderIsKept() throws {
        let results = [try result("m2", .movie), try result("s1", .series), try result("m1", .movie)]
        XCTAssertEqual(TVSearchGrouping.sections(results).first?.results.map(\.id), ["m2", "m1"])
    }

    func test_emptySections_areLeftOut() throws {
        XCTAssertEqual(TVSearchGrouping.sections([try result("m", .movie)]).map(\.id), ["movies"])
        XCTAssertTrue(TVSearchGrouping.sections([]).isEmpty)
    }

    /// A kind with no rail of its own, or none at all, still shows: nothing
    /// the server returned is dropped.
    func test_otherKinds_andUnknownKinds_goUnderOther() throws {
        let results = [try result("x", nil), try result("y", .season), try result("m", .movie)]
        let sections = TVSearchGrouping.sections(results)
        XCTAssertEqual(sections.map(\.id), ["movies", "other"])
        XCTAssertEqual(sections.last?.results.map(\.id), ["x", "y"])
    }
}
```

If `BaseItemKind` isn't `RawRepresentable` by string, encode it with `JSONEncoder` to get its JSON form for the fixture.

- [ ] **Step 2: Run them and see them fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVSearchGroupingTests`. Expected: build fails, "cannot find 'TVSearchGrouping' in scope".

- [ ] **Step 3: Implement the grouping**

`DionysusTV/Browse/TVSearchGrouping.swift`:

```swift
import Foundation

/// Search results as rails by type, in a fixed order, each keeping the
/// server's own order. Nothing is dropped: a kind without a rail of its own
/// goes under Other.
enum TVSearchGrouping {
    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        let results: [SearchResult]
    }

    private static let order: [(id: String, kinds: Set<BaseItemKind>, title: () -> String)] = [
        ("movies", [.movie], { String(localized: "Movies") }),
        ("shows", [.series], { String(localized: "Shows") }),
        ("episodes", [.episode], { String(localized: "Episodes") }),
        ("collections", [.boxSet], { String(localized: "Collections") }),
        ("playlists", [.playlist], { String(localized: "Playlists") })
    ]

    static func sections(_ results: [SearchResult]) -> [Section] {
        var sections = order.compactMap { entry -> Section? in
            let matching = results.filter { result in result.kind.map(entry.kinds.contains) ?? false }
            return matching.isEmpty ? nil : Section(id: entry.id, title: entry.title(), results: matching)
        }
        let known = order.reduce(into: Set<BaseItemKind>()) { $0.formUnion($1.kinds) }
        let other = results.filter { result in !(result.kind.map(known.contains) ?? false) }
        if !other.isEmpty {
            sections.append(Section(id: "other", title: String(localized: "Other"), results: other))
        }
        return sections
    }
}
```

Run the unit tests. Expected: PASS.

- [ ] **Step 4: Write the failing journeys**

Add to `A11yID.TV.Search`:

```swift
            static func section(_ id: String) -> String { "tv.search.section.\(id)" }
            static func recent(_ itemID: String) -> String { "tv.search.recent.\(itemID)" }
            static let clearRecent = "tv.search.recent.clear"
            static let noResults = "tv.search.noResults"
```

Replace `DionysusTVUITests/SearchJourneyTests.swift`:

```swift
import XCTest

final class SearchJourneyTests: TVUITestCase {
    private func openSearch(_ app: XCUIApplication) -> XCUIElement {
        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    private func focus(_ element: XCUIElement) {
        for _ in 0..<5 where !element.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(element))
    }

    func test_search_findsATitle_andOpensItsDetailPage() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("Quiet")
        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.section("movies")].exists, "Results sit under a rail for their type")
        focus(result)
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "A result opens its detail page, not the player")
        press(.menu)
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Quiet", "The query is still there")
    }

    /// A series could not be listed before M3: it had nowhere to go.
    func test_search_listsAShow_underShows() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("Northern")
        XCTAssertTrue(app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.seriesID)].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.section("shows")].exists)
    }

    func test_noResults_saysSo() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("zzzzzz")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.noResults].waitForExistence(timeout: 10))
    }

    /// An opened result becomes a recent search, shown while the field is
    /// empty, and Clear removes it.
    func test_recentSearches_listOpenedResults_andClearRemovesThem() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("Quiet")
        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        focus(result)
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.menu)

        // Leave Search and come back: the query is the shell's, so clear it.
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        press(.up, times: 3)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        let recent = app.buttons[A11yID.TV.Search.recent(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "With the field empty, what was opened is listed")

        let clear = app.buttons[A11yID.TV.Search.clearRecent]
        focus(recent)
        for _ in 0..<3 where !clear.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(clear))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { !recent.exists })
    }

    /// The M2 minors: the field's hint ran past the right edge.
    func test_searchField_staysOnScreen() {
        let app = launchAtHome()
        let field = openSearch(app)
        XCTAssertLessThanOrEqual(field.frame.maxX, app.frame.maxX - 40, "The field ends inside the screen")
        XCTAssertGreaterThanOrEqual(field.frame.minX, 184, "…and starts right of the rail")
    }

    func test_menu_opensTheRail_onSearchsRow() {
        let app = launchAtHome()
        _ = openSearch(app)
        press(.menu)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.search]))
    }
}
```

If the Simulator's `typeText` can't send delete to a tvOS search field, clear the query the way a person would: focus the keyboard's delete key and press Select five times; and if that proves unreliable, relaunch with `resetsState: false` and go straight to Search, where the field starts empty and the recent search is still stored.

Move `PlayerReturnJourneyTests.test_search_keepsItsQueryAndResults_acrossPlayback` out: `test_search_findsATitle_andOpensItsDetailPage` now covers it. Delete it there.

- [ ] **Step 5: Run them and see them fail**

Run: tvOS UI with `-only-testing:DionysusTVUITests/SearchJourneyTests`. Expected: FAIL (`tv.search.section.movies` not found).

- [ ] **Step 6: Rewrite `TVSearchView`**

Replace the `results` view, `playableResults` and the body's content in `DionysusTV/Browse/TVSearchView.swift`, keeping the existing `releaseRail()` hand-off, the `NavigationStack` and the `.onChange(of: viewModel.query)` exactly as they are:

```swift
/// Search (prototype screen 10), on the shared `SearchViewModel`: the system
/// keyboard, results as rails by type, and with the field empty the results
/// most recently opened. Every result opens a detail page.
///
/// The keyboard is the system's (Benjamin, 2026-10-01), so Left stays inside
/// it and Menu is the way to the rail. It is inset from both edges: flush
/// with the content's left edge its first key clipped when focused, and its
/// hint ran off the right of the screen.
struct TVSearchView: View {
    let viewModel: SearchViewModel
    @Binding var rememberedResultID: String?
    @FocusState private var focusedResultID: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvFocusHandoff) private var focusHandoff
    @Environment(\.tvPageClaimedFocus) private var claimedFocus
    @Environment(\.tvPageIsOnShow) private var isOnShow

    /// Room for a focused key's lift on the left, and for the hint on the
    /// right. Measured on the Simulator; see Step 8.
    private static let keyboardInset: CGFloat = 60

    private var sections: [TVSearchGrouping.Section] { TVSearchGrouping.sections(viewModel.results) }
    private var isIdle: Bool { viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var viewModel = viewModel
        TVPageScaffold {
            // `.searchable` draws its field only inside a navigation container.
            NavigationStack {
                content
                    .searchable(text: $viewModel.query)
            }
            .padding(.leading, Self.keyboardInset)
            .padding(.trailing, Self.keyboardInset + 80)
        }
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .task(id: viewModel.results.count + viewModel.history.count) { await viewModel.loadImagesIfNeeded() }
        .onAppear {
            if let rememberedResultID, allIDs.contains(rememberedResultID) { focusedResultID = rememberedResultID }
            releaseRail()
        }
        .onChange(of: focusHandoff) { releaseRail() }
        .onChange(of: isOnShow) { _, onShow in
            if onShow, let rememberedResultID, allIDs.contains(rememberedResultID) { focusedResultID = rememberedResultID }
        }
        .onChange(of: focusedResultID) { _, id in
            if let id, isOnShow { rememberedResultID = id }
        }
    }

    private var allIDs: [String] {
        isIdle ? viewModel.history.map { "recent.\($0.id)" } : viewModel.results.map(\.id)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                if isIdle {
                    recentSearches
                } else if sections.isEmpty, viewModel.loadState == .loaded {
                    Text("No results for “\(viewModel.query)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                        .accessibilityIdentifier(A11yID.TV.Search.noResults)
                } else if case .failed(let message) = viewModel.loadState {
                    Text(verbatim: message).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    ForEach(sections) { section in
                        TVRail(title: section.title, titleIdentifier: A11yID.TV.Search.section(section.id)) {
                            ForEach(section.results) { result in
                                tile(result, focusID: result.id, identifier: A11yID.TV.Search.result(result.id))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var recentSearches: some View {
        if !viewModel.history.isEmpty {
            TVRail(title: String(localized: "Recent Searches")) {
                ForEach(viewModel.history) { result in
                    tile(result, focusID: "recent.\(result.id)", identifier: A11yID.TV.Search.recent(result.id))
                }
                Button("Clear") { viewModel.clearHistory() }
                    .frame(height: TVTileMetrics.poster.height)
                    .accessibilityIdentifier(A11yID.TV.Search.clearRecent)
            }
        }
    }

    /// Search hints carry no watched or favourite state, so these tiles have
    /// no badges; the detail page shows both.
    private func tile(_ result: SearchResult, focusID: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                viewModel.recordSelection(result)
                open(.assetDetail(itemID: result.id))
            } label: {
                AsyncRemoteImage(
                    url: viewModel.imageURL(for: result, preferLandscape: false),
                    placeholderSystemImage: result.kind?.placeholderSystemImage ?? "film"
                )
                .frame(width: TVTileMetrics.poster.width, height: TVTileMetrics.poster.height)
            }
            .buttonStyle(.card)
            .focused($focusedResultID, equals: focusID)
            .accessibilityLabel(result.accessibilityDescription)
            .accessibilityIdentifier(identifier)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.name).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: TVTileMetrics.poster.width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    /// Lets the shell enable the rail once the keyboard has had its chance at
    /// focus, which it takes as soon as the page is laid out.
    private func releaseRail() {
        guard isOnShow else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            claimedFocus()
        }
    }
}
```

`SearchResult.imageURL` asks for `maxWidth: 200`, sized for an iOS list row; at 250pt on a 2x screen it is soft. Add a `maxWidth: Int = 200` parameter to `SearchResult.imageURL(images:preferLandscape:)` and to `SearchViewModel.imageURL(for:preferLandscape:)`, and pass `500` here (the same width `MediaItem.primaryImageURL` asks for). The default keeps iOS's requests byte-identical; `SearchResultTests` stays green.

Update `TVMainView`'s `TVSearchView(…)` call site (no `client` or `userID` now). In `TVPlayerPresenter`, delete `present(itemID:client:userID:)`: nothing calls it (`grep -rn "present(itemID" DionysusTV`).

- [ ] **Step 7: Run everything**

Run: tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: PASS.

- [ ] **Step 8: Measure the keyboard's inset**

On the Simulator, open Search and focus the keyboard's first key: its lifted frame must sit wholly right of the page's clip (x ≥ 154) with its shadow unclipped, and the hint text must end before the screen's right edge. Start from `keyboardInset = 60`; adjust until both hold, and screenshot the first key focused and the hint for the PR. If the system lays the keyboard out beyond the padding (it sizes to the window, not its container), wrap the `NavigationStack` in a fixed-width frame of `1920 - TVShellMetrics.contentInset - 2 × inset` instead and re-measure. Also run `idb` Left presses from the first key to confirm the M2 behaviour stands: focus stays in the keyboard, and Menu opens the rail.

- [ ] **Step 9: Docs, commit, PR**

CLAUDE.md's tvOS section: Search lists every kind, grouped by `TVSearchGrouping`; Recent Searches are opened results (the shared history), shown while the field is empty; search tiles have no badges because hints carry no user data; the keyboard's inset and why. TESTING.md: the rewritten `SearchJourneyTests`. Remove the "Search on tvOS: Left stays in the keyboard, its first key clips…" line from memory `open-issues-and-follow-ups`, keeping "Left stays in the keyboard" as a settled decision in `product-decisions`. Sync strings. After sign-off:

```bash
git add -u DionysusTV DionysusTVUITests DionysusPlayer/Core/Models/SearchResult.swift DionysusPlayer/Features/Search/SearchViewModel.swift
git add DionysusTV/Browse/TVSearchGrouping.swift DionysusTVTests/TVSearchGroupingTests.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md
git commit -m "Group Apple TV search results by type and add Recent Searches"
```

Open PR 5; merge with `--merge` once checks pass.

---

## PR 6 — Profile

### Task 10: Profile and its settings

**Files:**
- Create: `DionysusTV/Shell/Profile/TVSettingsRow.swift`, `TVAdvancedPlaybackView.swift`, `TVQuickConnectApprovalView.swift`, `TVTextPageView.swift`
- Move: `DionysusTV/Shell/TVProfileView.swift` → `DionysusTV/Shell/Profile/TVProfileView.swift` (rewritten), `TVProfileIdentity.swift` alongside it
- Modify: `DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift`, `DionysusPlayer/Features/Player/PlayerControlsOverlay.swift`, `DionysusPlayer/Features/Player/PlaybackStatsOverlay.swift` (keys moved out), `DionysusPlayer/App/AppState.swift`, `project.yml` (bundle `LICENSE` and `PRIVACY.md` in `DionysusTV`), `AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests/TVSignOutTests.swift`, `DionysusTVUITests/ProfileJourneyTests.swift`; existing `SidebarJourneyTests` and `AccountSwitchingJourneyTests` Profile steps

**Interfaces:**
- Consumes: `AppState.signOut()`, `changeServer()`, `setFollowsAppleTVUsers(_:)`, `ServerSessionStore.forgetAccount(userID:)`, `.credentials`, `.rememberedAccounts(forServer:)`; `SessionScopeSetting`; `QuickConnectApprovalViewModel`; `NextUpCountdownPreference`, `StreamDecisionMode`, `StreamingMaxBitrate`; the storage keys; `AppVersionInfo.footerText()`, `AetherEngineVersion.current`.
- Produces:
  - In `PlayerPreferenceKeys.swift`: `chaptersInScrubberEnabledStorageKey`, `chaptersInScrubberEnabledDefault`, `showPlaybackStatsButtonEnabledStorageKey`, `showPlaybackStatsButtonEnabledDefault` (moved, values unchanged, the `#if DEBUG` split on the stats default included).
  - `AppState.signOutForgettingAccount()` (tvOS only).
  - `TVSettingsRow(title: LocalizedStringKey, value: String? = nil, role: ButtonRole? = nil, identifier: String, action: @escaping () -> Void)`
  - `A11yID.TV.Profile`: `account`, `approveQuickConnect`, `signOut`, `autoCarousel`, `nextUpCountdown`, `chaptersInScrubber`, `advanced`, `license`, `privacyPolicy`, `version`, `streamingMode`, `maxBitrate`, `subtitleStyling`, `statsButton`, `quickConnectCode`, `quickConnectAuthorize`, `quickConnectMessage`, `textPage`. The M2 identifiers stay.

- [ ] **Step 1: Write the failing unit test**

`DionysusTVTests/TVSignOutTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// Sign Out forgets the account on this Apple TV; Switch User keeps it
/// remembered (Benjamin, 2026-10-01).
@MainActor
final class TVSignOutTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVSignOutTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func signedIn() -> (AppState, ServerSessionStore) {
        let store = ServerSessionStore(defaults: defaults)
        let server = ServerConfiguration(id: "server-1", name: "Home", baseURL: URL(string: "http://h")!)
        store.saveServerConfiguration(server)
        store.saveCredentials(StoredCredentials(username: "ana", password: "pw", accessToken: "t1", userID: "u-ana", serverID: server.id))
        store.saveCredentials(StoredCredentials(username: "ben", password: "pw", accessToken: "t2", userID: "u-ben", serverID: server.id))
        return (AppState(sessionStore: store), store)
    }

    func test_switchUser_keepsTheAccountRemembered() {
        let (appState, store) = signedIn()
        appState.signOut()
        XCTAssertEqual(Set(store.rememberedAccounts(forServer: "server-1").map(\.userID)), ["u-ana", "u-ben"])
        XCTAssertNil(store.credentials)
    }

    func test_signOut_forgetsOnlyTheAccountInUse() {
        let (appState, store) = signedIn()
        appState.signOutForgettingAccount()
        XCTAssertEqual(store.rememberedAccounts(forServer: "server-1").map(\.userID), ["u-ana"], "The other remembered account stays")
        XCTAssertNil(store.credentials)
        XCTAssertEqual(appState.phase, .login)
    }

    func test_signOut_withNobodySignedIn_changesNothing() {
        let store = ServerSessionStore(defaults: defaults)
        let appState = AppState(sessionStore: store)
        appState.signOutForgettingAccount()
        XCTAssertNil(store.credentials)
    }
}
```

Match `ServerConfiguration`'s and `ServerSessionStore`'s real initialisers and save methods (see `DionysusPlayerTests/App/AppStateTests.swift` and `SessionScopeSettingTests`), and isolate the keychain the way those tests do.

- [ ] **Step 2: Run it and see it fail**

Run: tvOS unit with `-only-testing:DionysusTVTests/TVSignOutTests`. Expected: build fails, "value of type 'AppState' has no member 'signOutForgettingAccount'".

- [ ] **Step 3: Implement `signOutForgettingAccount`, move the keys, bundle the texts**

In `DionysusPlayer/App/AppState.swift`, inside the existing `#if os(tvOS)` block that holds `setFollowsAppleTVUsers`:

```swift
    /// Profile's Sign Out: forgets this account on this Apple TV, then signs
    /// out. Switch User (`signOut()`) keeps it remembered, one press away on
    /// Who's Watching?; this is for someone who is leaving for good.
    func signOutForgettingAccount() {
        if let userID = sessionStore.credentials?.userID {
            sessionStore.forgetAccount(userID: userID)
        }
        signOut()
    }
```

Append to `DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift` the four declarations cut from `PlayerControlsOverlay.swift` (lines 6–10) and `PlaybackStatsOverlay.swift` (lines 519–528), with their doc comments and the `#if DEBUG … #else … #endif` around the stats default exactly as written there.

In `project.yml`, give `DionysusTV` the two bundled texts the same way `DionysusPlayer` has them (copy the `DionysusPlayer/Resources/LICENSE` entry with its `buildPhase: resources` override, and add `DionysusPlayer/Resources/PRIVACY.md`). Run `xcodegen generate`.

Run: the unit test, then an iOS build. Expected: PASS, BUILD SUCCEEDED.

- [ ] **Step 4: Write the failing journeys**

Add to `A11yID.TV.Profile`:

```swift
            static let account = "tv.profile.account"
            static let approveQuickConnect = "tv.profile.approveQuickConnect"
            static let signOut = "tv.profile.signOut"
            static let autoCarousel = "tv.profile.autoCarousel"
            static let nextUpCountdown = "tv.profile.nextUpCountdown"
            static let chaptersInScrubber = "tv.profile.chaptersInScrubber"
            static let advanced = "tv.profile.advanced"
            static let license = "tv.profile.license"
            static let privacyPolicy = "tv.profile.privacyPolicy"
            static let version = "tv.profile.version"
            static let streamingMode = "tv.profile.advanced.streamingMode"
            static let maxBitrate = "tv.profile.advanced.maxBitrate"
            static let subtitleStyling = "tv.profile.advanced.subtitleStyling"
            static let statsButton = "tv.profile.advanced.statsButton"
            static let quickConnectCode = "tv.profile.quickConnect.code"
            static let quickConnectAuthorize = "tv.profile.quickConnect.authorize"
            static let quickConnectMessage = "tv.profile.quickConnect.message"
            static let textPage = "tv.profile.textPage"
```

`DionysusTVUITests/ProfileJourneyTests.swift`:

```swift
import XCTest

final class ProfileJourneyTests: TVUITestCase {
    private func openProfile(_ app: XCUIApplication) {
        openRailFromHome(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.profile]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.switchUser]), "Profile opens with focus on Switch User")
    }

    func test_profile_showsWhoIsSignedIn_andTheVersions() {
        let app = launchAtHome()
        openProfile(app)
        XCTAssertEqual(app.staticTexts[A11yID.TV.Profile.name].label, UITestFixtureIdentity.username)
        XCTAssertEqual(app.staticTexts[A11yID.TV.Profile.server].label, UITestFixtureIdentity.serverName)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.version].label.contains("AetherEngine"))
    }

    func test_everySection_isReachable() {
        let app = launchAtHome()
        openProfile(app)
        for id in [A11yID.TV.Profile.approveQuickConnect, A11yID.TV.Profile.changeServer, A11yID.TV.Profile.signOut,
                   A11yID.TV.Profile.followsAppleTVUsers, A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown,
                   A11yID.TV.Profile.chaptersInScrubber, A11yID.TV.Profile.advanced, A11yID.TV.Profile.license, A11yID.TV.Profile.privacyPolicy] {
            let row = app.descendants(matching: .any)[id]
            for _ in 0..<14 where !(row.exists && row.hasFocus) { press(.down) }
            XCTAssertTrue(waitForFocus(row), "\(id) can be reached with Down")
        }
    }

    /// Select on a value row cycles its value.
    func test_autoCarousel_toggles() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.autoCarousel]
        pressDown(until: row)
        let before = row.value as? String
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (row.value as? String) != before })
    }

    func test_advanced_opens_andMenuReturnsToItsRow() {
        let app = launchAtHome()
        openProfile(app)
        let advanced = app.buttons[A11yID.TV.Profile.advanced]
        pressDown(until: advanced)
        press(.select)
        let mode = app.buttons[A11yID.TV.Profile.streamingMode]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(mode))
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.subtitleStyling].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.statsButton].exists)
        press(.menu)
        XCTAssertTrue(waitForFocus(advanced))
    }

    func test_approveQuickConnect_authorizesACode() {
        let app = launchAtHome()
        openProfile(app)
        let approve = app.buttons[A11yID.TV.Profile.approveQuickConnect]
        pressDown(until: approve)
        press(.select)
        let field = app.textFields[A11yID.TV.Profile.quickConnectCode]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        press(.select)
        field.typeText(UITestFixtureIdentity.quickConnectApprovableCode)
        press(.menu)
        let authorize = app.buttons[A11yID.TV.Profile.quickConnectAuthorize]
        pressDown(until: authorize)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.quickConnectMessage].waitForExistence(timeout: 10))
    }

    func test_quickConnectOff_hidesTheRow() {
        let app = launchAtHome(scenario: "quickConnectDisabled")
        openProfile(app)
        XCTAssertFalse(app.buttons[A11yID.TV.Profile.approveQuickConnect].exists)
    }

    func test_license_scrolls_andMenuReturns() {
        let app = launchAtHome()
        openProfile(app)
        let license = app.buttons[A11yID.TV.Profile.license]
        for _ in 0..<14 where !license.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(license))
        press(.select)
        let page = app.descendants(matching: .any)[A11yID.TV.Profile.textPage]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        press(.down, times: 3)
        press(.menu)
        XCTAssertTrue(waitForFocus(license))
    }

    /// Sign Out forgets the account: Who's Watching? lists it as an ordinary
    /// server user again, not as a remembered one.
    func test_signOut_forgetsTheAccount() {
        let app = launchAtHome()
        openProfile(app)
        let signOut = app.buttons[A11yID.TV.Profile.signOut]
        pressDown(until: signOut)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.userID)].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)].exists)
    }
}
```

Use the scenario name the onboarding journeys already use for a server with Quick Connect off (see `OnboardingJourneyTests.test_quickConnectDisabled_passwordUser_goesStraightToPassword`).

- [ ] **Step 5: Run them and see them fail**

Run: tvOS UI with `-only-testing:DionysusTVUITests/ProfileJourneyTests`. Expected: FAIL (`tv.profile.version` not found).

- [ ] **Step 6: Implement the row and the sub-screens**

`DionysusTV/Shell/Profile/TVSettingsRow.swift`:

```swift
import SwiftUI

/// One focusable row of Profile (prototype `.srow`): a title on the left and
/// an optional value on the right. Select runs the action; for a setting,
/// that cycles its value, since a row holds two to five choices.
struct TVSettingsRow: View {
    let title: LocalizedStringKey
    var value: String?
    var role: ButtonRole?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                Text(title)
                Spacer()
                if let value {
                    Text(verbatim: value).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier)
    }
}

/// A section heading, as the prototype's `.shead`.
struct TVSettingsHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 24)
            .padding(.leading, 34)
            .accessibilityAddTraits(.isHeader)
    }
}

extension CaseIterable where Self: Equatable, AllCases: RandomAccessCollection {
    /// The case after this one, wrapping: what a settings row's Select picks.
    var next: Self {
        let all = Array(Self.allCases)
        guard let index = all.firstIndex(of: self) else { return self }
        return all[(index + 1) % all.count]
    }
}
```

`DionysusTV/Shell/Profile/TVAdvancedPlaybackView.swift`:

```swift
import SwiftUI

/// Profile → Playback → Advanced, the iOS screen's four settings. Subtitle
/// Styling and the stats button are stored now and take effect when their
/// player features arrive on the Apple TV (M4); the two streaming settings
/// work today.
struct TVAdvancedPlaybackView: View {
    @AppStorage(streamDecisionModeStorageKey) private var streamDecisionMode: StreamDecisionMode = .allowTranscoding
    @AppStorage(streamingMaxBitrateStorageKey) private var streamingMaxBitrate: StreamingMaxBitrate = .unlimited
    @AppStorage(styledASSSubtitlesEnabledStorageKey) private var isStyledASSEnabled = styledASSSubtitlesEnabledDefault
    @AppStorage(showPlaybackStatsButtonEnabledStorageKey) private var showsStatsButton = showPlaybackStatsButtonEnabledDefault
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: String?

    private func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced").font(.title2.bold()).padding(.leading, 34)
            TVSettingsHeader(title: "Streaming")
            TVSettingsRow(title: "Streaming", value: streamDecisionMode.displayName, identifier: A11yID.TV.Profile.streamingMode) {
                streamDecisionMode = streamDecisionMode.next
            }
            .focused($focus, equals: "mode")
            if streamDecisionMode == .allowTranscoding {
                TVSettingsRow(title: "Max Streaming Bitrate", value: streamingMaxBitrate.displayName, identifier: A11yID.TV.Profile.maxBitrate) {
                    streamingMaxBitrate = streamingMaxBitrate.next
                }
            }
            TVSettingsHeader(title: "Subtitles")
            TVSettingsRow(title: "Subtitle Styling", value: onOff(isStyledASSEnabled), identifier: A11yID.TV.Profile.subtitleStyling) {
                isStyledASSEnabled.toggle()
            }
            TVSettingsHeader(title: "Diagnostics")
            TVSettingsRow(title: "Show Playback Stats Button", value: onOff(showsStatsButton), identifier: A11yID.TV.Profile.statsButton) {
                showsStatsButton.toggle()
            }
        }
        .frame(width: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, "mode")
    }
}
```

Read `AdvancedPlaybackSettingsView.swift` for the iOS section titles and footers and use the same strings, so the catalog gains nothing new for them.

`DionysusTV/Shell/Profile/TVQuickConnectApprovalView.swift`:

```swift
import SwiftUI

/// Approves another device's Quick Connect code from this Apple TV, on the
/// shared `QuickConnectApprovalViewModel`. The code is typed with the system
/// keyboard (and so the Continuity Keyboard on a nearby iPhone).
struct TVQuickConnectApprovalView: View {
    @State var viewModel: QuickConnectApprovalViewModel
    @State private var text = ""
    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 30) {
            Text("Approve Quick Connect Code").font(.title2.bold())
            Text("Enter the code shown on the other device. It will sign in to \(viewModel.serverName) as \(viewModel.userName).")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            TextField("Code", text: $text)
                .keyboardType(.numberPad)
                .frame(width: 500)
                .focused($focus, equals: "code")
                .accessibilityIdentifier(A11yID.TV.Profile.quickConnectCode)
                .onChange(of: text) { _, raw in
                    viewModel.setCode(raw)
                    if text != viewModel.code { text = viewModel.code }
                }
            Button {
                Task { await viewModel.authorize() }
            } label: {
                Text("Authorize").frame(width: 500)
            }
            .disabled(!viewModel.canSubmit)
            .focused($focus, equals: "authorize")
            .accessibilityIdentifier(A11yID.TV.Profile.quickConnectAuthorize)

            Group {
                switch viewModel.state {
                case .approved:
                    Text("Approved. The other device is signing in.")
                case .failed(let message):
                    Text(verbatim: message)
                case .submitting:
                    ProgressView()
                case .entering:
                    EmptyView()
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 900, minHeight: 80)
            .accessibilityIdentifier(A11yID.TV.Profile.quickConnectMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, "code")
    }
}
```

The identifier on the `Group` lands on whichever text shows; if the audit or the journey can't find it, put the identifier on each `Text` instead.

`DionysusTV/Shell/Profile/TVTextPageView.swift`:

```swift
import SwiftUI

/// A long bundled text (the license, the privacy policy) on the Apple TV,
/// where a scroll view moves only with focus: the text is cut into
/// paragraphs, each focusable, so Up and Down scroll through it.
struct TVTextPageView: View {
    let title: LocalizedStringKey
    let paragraphs: [AttributedString]
    @FocusState private var focused: Int?

    /// The bundled file split on blank lines, with the privacy policy's
    /// headers and bullets styled as `PrivacyPolicyView` styles them.
    static func paragraphs(resource: String, extension ext: String?, markdown: Bool) -> [AttributedString] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return [AttributedString(String(localized: "This text is unavailable."))]
        }
        return raw.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { markdown ? styled($0) : AttributedString($0) }
    }

    private static func styled(_ block: String) -> AttributedString {
        var result = AttributedString()
        let lines = block.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var content = line.trimmingCharacters(in: .whitespaces)
            var headerLevel = 0
            while content.hasPrefix("#") { headerLevel += 1; content.removeFirst() }
            content = content.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            if content.hasPrefix("- ") { prefix = "•  "; content.removeFirst(2) }
            var parsed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
            if headerLevel > 0 { parsed.font = headerLevel <= 1 ? .title2.bold() : .headline }
            result += AttributedString(prefix) + parsed
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(title).font(.title2.bold())
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(focused == index ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
                        .focusable()
                        .focused($focused, equals: index)
                }
            }
            .padding(.horizontal, 240)
            .padding(.vertical, 80)
        }
        .accessibilityIdentifier(A11yID.TV.Profile.textPage)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, 0)
    }
}
```

`A11yID` forbids an identifier on a screen-root container; if the audit or a journey shows it overwriting the paragraphs' own, move it onto the title `Text` and select that in `test_license_scrolls_andMenuReturns`.

- [ ] **Step 7: Rewrite `TVProfileView`**

Move `TVProfileView.swift` and `TVProfileIdentity.swift` into `DionysusTV/Shell/Profile/` with `git mv`. Keep `TVChangeServerConfirmation` as it is. Replace the `TVProfileView` struct:

```swift
/// Profile (prototype screen 11): who is signed in and the app's versions on
/// the left, the settings as focusable rows on the right. Profile is the only
/// way to settings; there is no separate Settings page.
///
/// The iOS sections minus Downloads, 3D Depth Effects and Theme, plus Switch
/// User and the two Apple TV session settings. Four of the Playback settings
/// are stored now and take effect with their player features in M4.
struct TVProfileView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarousel = true
    @AppStorage(nextUpCountdownStorageKey) private var nextUpCountdown: NextUpCountdownPreference = .seconds30
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var chaptersInScrubber = chaptersInScrubberEnabledDefault
    @AppStorage(streamDecisionModeStorageKey) private var streamDecisionMode: StreamDecisionMode = .allowTranscoding

    private enum Sheet: String, Identifiable {
        case changeServer, quickConnect, advanced, license, privacyPolicy
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    @State private var quickConnectAvailable = false
    @FocusState private var focus: String?
    @State private var remembered: String?
    /// Copies to draw from: these settings live in the keychain, which
    /// nothing observes.
    @State private var followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers
    @State private var selectsUserEveryRelaunch = SessionScopeSetting.selectsUserEveryRelaunch

    private var user: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    private var server: ServerConfiguration? { appState.sessionStore.serverConfiguration }

    private func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }

    /// Switch User first: it is the default focus, as in M2.
    private var focusIDs: [String] {
        [A11yID.TV.Profile.switchUser]
            + (quickConnectAvailable ? [A11yID.TV.Profile.approveQuickConnect] : [])
            + [A11yID.TV.Profile.changeServer, A11yID.TV.Profile.signOut, A11yID.TV.Profile.followsAppleTVUsers]
            + (followsAppleTVUsers ? [] : [A11yID.TV.Profile.selectsUserEveryRelaunch])
            + [A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown, A11yID.TV.Profile.chaptersInScrubber,
               A11yID.TV.Profile.advanced, A11yID.TV.Profile.license, A11yID.TV.Profile.privacyPolicy]
    }

    var body: some View {
        TVPageScaffold {
            HStack(alignment: .top, spacing: 60) {
                brandPane
                rows
            }
        }
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $remembered)
        .task {
            guard let client = appState.apiClient else { return }
            quickConnectAvailable = await QuickConnectApprovalViewModel.isAvailable(on: client)
        }
        // Covers of our own rather than `.confirmationDialog` or a pushed
        // page: Menu closes a cover, and the row beneath keeps focus.
        .fullScreenCover(item: $sheet) { sheet in
            switch sheet {
            case .changeServer:
                TVChangeServerConfirmation { appState.changeServer() }
            case .quickConnect:
                if let client = appState.apiClient {
                    TVQuickConnectApprovalView(viewModel: QuickConnectApprovalViewModel(
                        client: client, userName: user?.name ?? "", serverName: server?.name ?? ""
                    ))
                }
            case .advanced:
                TVAdvancedPlaybackView()
            case .license:
                TVTextPageView(title: "License", paragraphs: TVTextPageView.paragraphs(resource: "LICENSE", extension: nil, markdown: false))
            case .privacyPolicy:
                TVTextPageView(title: "Privacy Policy", paragraphs: TVTextPageView.paragraphs(resource: "PRIVACY", extension: "md", markdown: true))
            }
        }
    }

    /// The prototype's left pane: who this is, and what's running.
    private var brandPane: some View {
        VStack(spacing: 26) {
            if let user {
                UserAvatar(user: user, serverURL: server?.baseURL, size: 220)
                Text(verbatim: user.name).font(.title2.bold()).accessibilityIdentifier(A11yID.TV.Profile.name)
            }
            if let server {
                Text(verbatim: server.name).foregroundStyle(.secondary).accessibilityIdentifier(A11yID.TV.Profile.server)
                Text(verbatim: server.baseURL.host() ?? server.baseURL.absoluteString).font(.caption).foregroundStyle(.tertiary)
            }
            // "AetherEngine" is a product name, not translated.
            Text(verbatim: "\(AppVersionInfo.footerText())\nAetherEngine \(AetherEngineVersion.current)")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 30)
                .accessibilityIdentifier(A11yID.TV.Profile.version)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
    }

    private var rows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile").font(.title2.bold()).padding(.leading, 34).accessibilityAddTraits(.isHeader)

                TVSettingsHeader(title: "Account")
                row("Switch User", id: A11yID.TV.Profile.switchUser) { appState.signOut() }
                if quickConnectAvailable {
                    row("Approve Quick Connect Code", id: A11yID.TV.Profile.approveQuickConnect) { sheet = .quickConnect }
                }
                row("Change Server", id: A11yID.TV.Profile.changeServer) { sheet = .changeServer }
                row("Sign Out", role: .destructive, id: A11yID.TV.Profile.signOut) { appState.signOutForgettingAccount() }

                TVSettingsHeader(title: "Apple TV Users")
                row("Follow Apple TV Users", value: onOff(followsAppleTVUsers), id: A11yID.TV.Profile.followsAppleTVUsers) {
                    appState.setFollowsAppleTVUsers(!followsAppleTVUsers)
                    followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers
                }
                if !followsAppleTVUsers {
                    row("Select a User Every Relaunch", value: onOff(selectsUserEveryRelaunch), id: A11yID.TV.Profile.selectsUserEveryRelaunch) {
                        SessionScopeSetting.setSelectsUserEveryRelaunch(!selectsUserEveryRelaunch)
                        selectsUserEveryRelaunch = SessionScopeSetting.selectsUserEveryRelaunch
                    }
                }
                footer("Attempts to match Jellyfin users to this Apple TV's users. Turn off to keep user switching inside the app, and when users become out of sync.")

                TVSettingsHeader(title: "Home")
                row("Auto Carousel", value: onOff(autoCarousel), id: A11yID.TV.Profile.autoCarousel) { autoCarousel.toggle() }

                TVSettingsHeader(title: "Playback")
                row("Next Episode Countdown", value: nextUpCountdown.displayName, id: A11yID.TV.Profile.nextUpCountdown) {
                    nextUpCountdown = nextUpCountdown.next
                }
                row("Chapters in Scrubber", value: onOff(chaptersInScrubber), id: A11yID.TV.Profile.chaptersInScrubber) { chaptersInScrubber.toggle() }
                row("Advanced", value: streamDecisionMode.displayName, id: A11yID.TV.Profile.advanced) { sheet = .advanced }
                footer("Next Episode Countdown sets how long before the end of an episode to count down the next one, if end credits aren't detected. Chapters in Scrubber overlays chapter markers on the scrubber with magnetic snapping.")

                TVSettingsHeader(title: "About")
                row("License", id: A11yID.TV.Profile.license) { sheet = .license }
                row("Privacy Policy", id: A11yID.TV.Profile.privacyPolicy) { sheet = .privacyPolicy }
            }
            .padding(.top, 90)
            .padding(.bottom, 240)
            .padding(.trailing, 120)
        }
        .scrollClipDisabled()
    }

    private func row(_ title: LocalizedStringKey, value: String? = nil, role: ButtonRole? = nil, id: String, action: @escaping () -> Void) -> some View {
        TVSettingsRow(title: title, value: value, role: role, identifier: id, action: action)
            .focused($focus, equals: id)
    }

    private func footer(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 34).frame(maxWidth: 820, alignment: .leading)
    }
}
```

`TVChangeServerConfirmation`'s destructive button calls `dismiss()` then `onConfirm()`; it works unchanged under `.fullScreenCover(item:)`. The Follow footer is Benjamin's own copy from M2: keep it word for word.

The existing M2 journeys read the two session toggles as `Toggle`s (`app.switches[…]`); they are rows now. Update `AccountSwitchingJourneyTests` and `SidebarJourneyTests` to query `app.buttons[A11yID.TV.Profile.followsAppleTVUsers]` and to read its `value` ("On"/"Off" are localized: compare the value before and after a press, never to a literal).

- [ ] **Step 8: Run everything**

Run `xcodegen generate`, then tvOS unit, tvOS UI, iOS unit, iOS smoke. Expected: PASS. Extend `AccessibilityAuditTests`' tvOS counterpart, if `DionysusTVUITests` has one, to open Profile, Advanced and a text page; if it has none, add `DionysusTVUITests/AccessibilityAuditTests.swift` running `performAccessibilityAudit(for:)` with the same structural audit types the iOS suite uses (copy its option set and its documented exclusions) over Home, a movie page, a show page, a library grid, Search and Profile.

- [ ] **Step 9: Look at it**

On the Simulator against the LAN test server, compare Profile with prototype screen 11, and check: Menu from each cover returns to its row; Auto Carousel off stops Home's hero; Streaming set to Direct Play Always changes the route a played title takes.

- [ ] **Step 10: Docs, commit, PR**

- CLAUDE.md's tvOS section: Profile's layout and sections; Sign Out against Switch User; sub-screens are covers (Menu closes them); the text pages are split into focusable paragraphs because a tvOS scroll view only moves with focus; which four settings wait for M4; the three keys now in `PlayerPreferenceKeys.swift`.
- `docs/superpowers/specs/2026-09-29-tvos-app-design.md`: milestone 3's line gains "(done: PRs #…)" and the M2 line loses "(in progress …)".
- TESTING.md: `ProfileJourneyTests`, `TVSignOutTests`, the audit.
- `PRIVACY.md`: read the "Apple TV" paragraph M2 added; Sign Out deleting a remembered account is a way to remove stored credentials, so add one sentence saying so. Nothing else changes: no new identifier, permission, dependency or destination.
- Memory: update `tvos-app-direction` (M3 done, M4 next) and `open-issues-and-follow-ups` (the Bedroom memory check from Task 4, if still owed).
- Sync strings.

After sign-off:

```bash
git add -u DionysusTV DionysusTVUITests DionysusPlayer/Features/Player/PlayerControlsOverlay.swift DionysusPlayer/Features/Player/PlaybackStatsOverlay.swift DionysusPlayer/App/AppState.swift project.yml
git add DionysusTV/Shell/Profile DionysusTVTests/TVSignOutTests.swift DionysusTVUITests/ProfileJourneyTests.swift DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md TESTING.md PRIVACY.md docs/superpowers/specs
git commit -m "Add the Apple TV Profile screen's settings and Sign Out"
```

Open PR 6; merge with `--merge` once checks pass.

---

## After the last PR

Run a final review of the whole milestone against the spec (superpowers:requesting-code-review), as M1 and M2 had, and fix what it finds in one follow-up PR. Deferred minors go to memory `open-issues-and-follow-ups`.

## Self-review notes

- **Spec coverage:** navigation and the cap (Tasks 1, 4); shared tiles and the badge rule (2); Home (8); movie, show, box set and playlist pages (4, 5, 6); the grid and alphabet bar (7); Search (9); Profile (10); testing and docs in each task; delivery in six PRs, with Home and the grid swapped as explained under "Delivery order".
- **Two spec items the plan settles:** a playlist row plays the item with the playlist as its queue (iOS's behaviour); the hero advances every five seconds (iOS's interval).
- **One thing the spec didn't foresee:** Search tiles carry no badges, because Jellyfin's search hints carry no watched or favourite state. The detail page shows both.
