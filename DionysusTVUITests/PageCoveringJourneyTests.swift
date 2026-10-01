import XCTest

/// Only the topmost page draws its content (`TVPageStack`): the player tears
/// the whole shell down, rail included, and it comes back as it was, with the
/// rail collapsed, focus on what was played and Search's query intact.
final class PageCoveringJourneyTests: TVUITestCase {
    /// Continue Watching's second tile, so a return to the first tile can't
    /// pass for focus being restored.
    private let secondTileID = UITestFixtureIdentity.episodeID(season: 1, episode: 1)

    func test_player_tearsDownHome_andFocusReturnsToThePlayedTile() {
        let app = launchAtHome()
        let second = app.buttons[A11yID.TV.Main.tile(secondTileID)]
        press(.right)
        XCTAssertTrue(waitForFocus(second))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        // XCUITest can't see under the player, a UIKit modal; it reports the
        // pages covering the shell instead (`TVPageStack`).
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.coveringPages(1)].waitForExistence(timeout: 5),
                      "The player covers the shell, so Home is torn down")
        press(.menu)
        XCTAssertTrue(waitForFocus(second), "Focus returns to the tile that was played")
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail is back, collapsed")
    }

    func test_player_overALibrary_tearsTheShellDown_andReturnsToItsTile() {
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
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.coveringPages(1)].waitForExistence(timeout: 5),
                      "The player covers the shell, so the library and the rail are torn down")
        press(.menu)
        XCTAssertTrue(waitForFocus(played), "Focus returns to the tile that was played")
        XCTAssertTrue(waitForCollapsed(movies), "The rail is back, collapsed, on the library's row")
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
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.coveringPages(1)].waitForExistence(timeout: 5),
                      "The player covers the shell, so Search is torn down")
        press(.menu)
        XCTAssertTrue(waitForFocus(result), "Search comes back with its results, focus on the one played")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Quiet")
    }
}
