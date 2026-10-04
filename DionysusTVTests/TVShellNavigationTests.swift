import XCTest
@testable import Dionysus

/// Where the shell is, and which sidebar row focus may land on (Benjamin,
/// 2026-10-01): every row but the Libraries group is a destination; the rail
/// is always drawn, and entering it lands on the destination's own row.
final class TVShellNavigationTests: XCTestCase {
    private func library(_ id: String) -> MediaItem {
        let dto = BaseItemDto(id: id, name: id, type: .collectionFolder, collectionType: "movies")
        return MediaItem(dto: dto, images: ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil))
    }

    private lazy var four = (1...4).map { library("l\($0)") }
    private lazy var six = (1...6).map { library("l\($0)") }

    func test_startsAtHome() {
        let nav = TVShellNavigation()
        XCTAssertEqual(nav.destination, .home)
        XCTAssertEqual(nav.railAnchor(libraries: four), .home)
    }

    func test_selectingARow_navigatesThere() {
        var nav = TVShellNavigation()
        XCTAssertEqual(nav.select(.search), .navigated)
        XCTAssertEqual(nav.destination, .search)
        XCTAssertEqual(nav.select(.library("l2")), .navigated)
        XCTAssertEqual(nav.destination, .library("l2"))
        XCTAssertEqual(nav.railAnchor(libraries: four), .library("l2"))
    }

    /// The Libraries row isn't a page: it closes and opens in place. It
    /// starts open (Benjamin, 2026-10-01), as the prototype's 6b shows it.
    func test_theLibrariesGroup_startsOpen_andSelectingItTogglesIt_andStaysPut() {
        var nav = TVShellNavigation()
        XCTAssertTrue(nav.librariesExpanded)
        XCTAssertEqual(nav.select(.librariesGroup), .toggledGroup)
        XCTAssertFalse(nav.librariesExpanded)
        XCTAssertEqual(nav.destination, .home)
        XCTAssertEqual(nav.select(.librariesGroup), .toggledGroup)
        XCTAssertTrue(nav.librariesExpanded)
    }

    /// Collapsed, only the destination's row takes focus, so Left from any
    /// height lands on it rather than the nearest row.
    func test_collapsed_onlyTheAnchorIsFocusable() {
        var nav = TVShellNavigation()
        _ = nav.select(.profile)
        XCTAssertEqual(nav.focusableRows(isExpanded: false, libraries: four), [.profile])
    }

    func test_expanded_everyRowIsFocusable() {
        let nav = TVShellNavigation()
        XCTAssertEqual(
            nav.focusableRows(isExpanded: true, libraries: four),
            Set(TVSidebarLayout.rows(libraries: four, librariesExpanded: true))
        )
    }

    /// A folded library has no row in the collapsed rail, so focus enters on
    /// the Libraries row, which stands for it there.
    func test_foldedLibraryDestination_anchorsOnTheGroup() {
        var nav = TVShellNavigation()
        _ = nav.select(.library("l6"))
        XCTAssertEqual(nav.railAnchor(libraries: six), .librariesGroup)
        XCTAssertEqual(nav.focusableRows(isExpanded: false, libraries: six), [.librariesGroup])
    }

    /// Entering the rail on a folded library opens the group again, even if
    /// it was closed since, so the library's own row is there to focus.
    func test_enteringTheRail_revealsAFoldedDestination() {
        var nav = TVShellNavigation()
        _ = nav.select(.library("l6"))
        _ = nav.select(.librariesGroup)
        XCTAssertFalse(nav.librariesExpanded)
        XCTAssertEqual(nav.enterRail(libraries: six), .library("l6"))
        XCTAssertTrue(nav.librariesExpanded)
    }

    func test_enteringTheRail_landsOnTheDestination() {
        var nav = TVShellNavigation()
        XCTAssertEqual(nav.enterRail(libraries: four), .home)
        _ = nav.select(.library("l3"))
        XCTAssertEqual(nav.enterRail(libraries: four), .library("l3"))
    }

    /// The selected look sits on the destination's row, or on the Libraries
    /// row while that row stands for it (rail collapsed, or the group closed).
    func test_highlight_followsTheDestination_orTheGroupStandingForIt() {
        var nav = TVShellNavigation()
        _ = nav.select(.library("l6"))
        XCTAssertTrue(nav.isHighlighted(.librariesGroup, isExpanded: false, libraries: six))
        XCTAssertFalse(nav.isHighlighted(.library("l6"), isExpanded: false, libraries: six))
        XCTAssertTrue(nav.isHighlighted(.library("l6"), isExpanded: true, libraries: six))
        XCTAssertFalse(nav.isHighlighted(.librariesGroup, isExpanded: true, libraries: six))
        XCTAssertFalse(nav.isHighlighted(.home, isExpanded: true, libraries: six))
    }

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

    /// Search is the system's full-screen layout (Benjamin, 2026-10-04), so
    /// the collapsed rail slides off screen there. Open, it shows as ever.
    func test_onSearch_theCollapsedRailIsHidden() {
        var nav = TVShellNavigation()
        XCTAssertFalse(nav.hidesCollapsedRail)
        _ = nav.select(.search)
        XCTAssertTrue(nav.hidesCollapsedRail)
        _ = nav.select(.profile)
        XCTAssertFalse(nav.hidesCollapsedRail)
    }

    /// A detail page opened from Search sits beside the rail like any other.
    func test_aPageOpenedFromSearch_bringsTheRailBack() {
        var nav = TVShellNavigation()
        _ = nav.select(.search)
        _ = nav.push(.assetDetail(itemID: "m"))
        XCTAssertFalse(nav.hidesCollapsedRail)
        _ = nav.pop()
        XCTAssertTrue(nav.hidesCollapsedRail)
    }

    /// While the rail is off screen a chevron at the left edge says where it
    /// went (Benjamin, 2026-10-04); open, the sidebar itself is there.
    func test_theEdgeChevron_showsOnlyWhileTheRailIsOffScreen() {
        var nav = TVShellNavigation()
        XCTAssertFalse(nav.showsEdgeChevron(isExpanded: false))
        _ = nav.select(.search)
        XCTAssertTrue(nav.showsEdgeChevron(isExpanded: false))
        XCTAssertFalse(nav.showsEdgeChevron(isExpanded: true))
        _ = nav.push(.assetDetail(itemID: "m"))
        XCTAssertFalse(nav.showsEdgeChevron(isExpanded: false))
    }

    /// Choosing another page leaves Search, which then starts fresh when
    /// chosen again (Benjamin, 2026-10-04). Folding the Libraries group or
    /// choosing Search again stays on it; a pushed page isn't a choice at all.
    func test_choosingAnotherPage_leavesSearch() {
        var nav = TVShellNavigation()
        XCTAssertFalse(nav.selectionLeavesSearch(.profile), "Not on Search")
        _ = nav.select(.search)
        XCTAssertTrue(nav.selectionLeavesSearch(.home))
        XCTAssertTrue(nav.selectionLeavesSearch(.library("l1")))
        XCTAssertFalse(nav.selectionLeavesSearch(.search))
        XCTAssertFalse(nav.selectionLeavesSearch(.librariesGroup))
    }
}
