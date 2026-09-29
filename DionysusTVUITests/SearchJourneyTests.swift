import XCTest

final class SearchJourneyTests: TVUITestCase {
    /// The sidebar opens with a Left press from Home's first tile, Search is
    /// the item below Home, and a typed query lists a playable result that
    /// opens the player.
    func test_searchFromSidebar_findsTitle_andPlaysIt() {
        let app = launch(seedSession: true)
        let firstTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstTile))

        press(.left)
        press(.down)
        press(.select)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search should be the sidebar item below Home")
        field.typeText("Quiet")

        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        for _ in 0..<4 where !result.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(result))
        press(.select)

        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
    }
}
