import XCTest

/// The player is laid over the page that opened it, which stays as it was:
/// leaving the player lands on the title played, wherever in the page it is,
/// with the rail collapsed and Search's query intact.
final class PlayerReturnJourneyTests: TVUITestCase {
    /// Continue Watching's second tile, so a return to the first tile can't
    /// pass for focus being restored.
    private let secondTileID = UITestFixtureIdentity.episodeID(season: 1, episode: 1)

    func test_player_overHome_returnsToThePlayedTile() {
        let app = launchAtHome()
        let second = app.buttons[A11yID.TV.Main.tile(secondTileID)]
        press(.right)
        XCTAssertTrue(waitForFocus(second))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(second), "Focus returns to the tile that was played")
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail is back, collapsed")
    }

    func test_player_overALibrary_returnsToItsTile() {
        let app = launchAtHome()
        let movies = openMovies(app)
        let firstTile = firstLibraryTile(app)
        // The second tile, so a return to the first can't pass for restored focus.
        let firstID = firstTile.identifier
        press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let played = app.buttons[focused.identifier]
        XCTAssertNotEqual(focused.identifier, firstID)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForLift(played), "Focus is still on the tile that was played")
        XCTAssertFalse(app.buttons[firstID].frame.width > 260, "And not on the first tile")
        XCTAssertTrue(waitForCollapsed(movies), "The rail is collapsed, on the library's row")
    }

    /// Two rows down, the tile sits below the first screen of the lazy grid:
    /// coming back must land on it, not at the top.
    func test_player_fromBelowTheFirstScreen_returnsToThePlayedTile() {
        let app = launchAtHome()
        _ = openMovies(app)
        let firstID = firstLibraryTile(app).identifier
        press(.down, times: 2)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let playedID = focused.identifier
        XCTAssertNotEqual(playedID, firstID)
        let first = app.buttons[firstID]
        XCTAssertTrue(!first.exists || first.frame.minY < 0, "The grid has scrolled its first row off the top")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForLift(app.buttons[playedID]), "Focus is still on the tile that was played")
        let top = app.buttons[firstID]
        XCTAssertTrue(!top.exists || top.frame.minY < 0, "The grid is where it was left, not back at the top")
    }

    /// Whether a library tile has focus, read from its frame: a focused card
    /// is drawn larger. After the player closes over a page that was never
    /// rebuilt, XCUITest reports `hasFocus` false for every tile, though the
    /// focus is there (a press moves it on from the right tile).
    private func waitForLift(_ tile: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) { tile.exists && tile.frame.width > 260 }
    }

    func test_search_keepsItsQueryAndResults_acrossPlayback() {
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
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(result), "Search comes back with its results, focus on the one played")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Quiet")
    }
}
