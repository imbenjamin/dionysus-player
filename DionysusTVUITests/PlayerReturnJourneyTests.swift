import XCTest

/// A detail page is laid over the page that opened it, which stays as it
/// was: Menu lands on the tile it came from, wherever in the page it is,
/// with the rail collapsed and Search's query intact.
final class PlayerReturnJourneyTests: TVUITestCase {
    /// Continue Watching's second tile, so a return to the first tile can't
    /// pass for focus being restored.
    private let secondTileID = UITestFixtureIdentity.episodeID(season: 1, episode: 1)

    func test_detail_overHome_returnsToTheTile() {
        let app = launchAtHome()
        let second = app.buttons[A11yID.TV.Main.tile(secondTileID)]
        press(.right)
        XCTAssertTrue(waitForFocus(second))
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(second), "Focus returns to the tile that was opened")
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail is back, collapsed")
    }

    func test_detail_overALibrary_returnsToItsTile() {
        let app = launchAtHome()
        let movies = openMovies(app)
        let firstTile = firstLibraryTile(app)
        // The second tile, so a return to the first can't pass for restored focus.
        let firstID = firstTile.identifier
        press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let opened = app.buttons[focused.identifier]
        XCTAssertNotEqual(focused.identifier, firstID)
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(opened), "Focus is still on the tile that was opened")
        XCTAssertFalse(app.buttons[firstID].hasFocus, "And not on the first tile")
        XCTAssertTrue(waitForCollapsed(movies), "The rail is collapsed, on the library's row")
    }

    /// Two rows down, the tile sits below the first screen of the lazy grid:
    /// coming back must land on it, not at the top.
    func test_detail_fromBelowTheFirstScreen_returnsToTheTile() {
        let app = launchAtHome()
        _ = openMovies(app)
        let firstID = firstLibraryTile(app).identifier
        let startY = app.buttons[firstID].frame.minY
        press(.down, times: 2)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let openedID = focused.identifier
        XCTAssertNotEqual(openedID, firstID)
        // The grid scrolls only as far as the focused row needs, so the
        // first row may still be on screen: its position is what's compared.
        let first = app.buttons[firstID]
        XCTAssertTrue(poll(timeout: 5) { !first.exists || first.frame.minY < startY - 20 }, "The grid has scrolled")
        let scrolledY = first.exists ? first.frame.minY : nil
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[openedID]), "Focus is still on the tile that was opened")
        let top = app.buttons[firstID]
        XCTAssertTrue(poll(timeout: 5) { scrolledY.map { top.exists && abs(top.frame.minY - $0) < 4 } ?? !top.exists }, "The grid is where it was left, not back at the top")
    }

    func test_search_keepsItsQueryAndResults_acrossADetailPage() {
        let app = launchAtHome()
        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Quiet")
        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        for _ in 0..<4 where !result.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(result))
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(result), "Search comes back with its results, focus on the one opened")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Quiet")
    }
}
