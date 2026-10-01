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
}
