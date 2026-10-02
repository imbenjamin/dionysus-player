import XCTest

final class SearchJourneyTests: TVUITestCase {
    /// The rail opens with a Left press from Home's first tile, Search is the
    /// row below Home, and a typed query lists a result that opens its
    /// detail page, which plays it.
    func test_searchFromSidebar_findsTitle_andOpensItsDetailPage() {
        let app = launch(seedSession: true)
        let firstTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstTile))

        // The sidebar opens on Home's row; Search is the row below it.
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.select)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search should be the sidebar item below Home")
        field.typeText("Quiet")

        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        for _ in 0..<4 where !result.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(result))
        playFromFocusedTile(app)
    }
}
