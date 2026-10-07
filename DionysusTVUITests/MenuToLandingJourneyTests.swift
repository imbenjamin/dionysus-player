import XCTest

/// Away from a page's landing view, Menu first goes back to it: the top, with
/// focus on the item the page opens on. Menu again does what it always did,
/// popping a pushed page or opening the sidebar (Benjamin, 2026-10-07).
/// Home's own journey is in `HomeJourneyTests`.
final class MenuToLandingJourneyTests: TVUITestCase {
    func test_detailPage_menuBelowTheHeader_returnsToPlay_thenPops() {
        let app = launchAtHomeTile()
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        let play = openDetailFromFocusedTile(app)
        let playTop = play.frame.minY
        press(.down, times: 2)
        XCTAssertTrue(poll(timeout: 5) { !play.hasFocus }, "Focus is below the header")
        press(.menu)
        XCTAssertTrue(waitForFocus(play), "Menu goes back to Play")
        XCTAssertTrue(poll(timeout: 5) { abs(play.frame.minY - playTop) < 2 }, "…at the page's top")
        press(.menu)
        XCTAssertTrue(waitForFocus(tile), "Menu again pops the page")
    }

    func test_library_menuOnceScrolled_returnsToTheFirstTile_thenOpensTheRail() {
        let app = launchAtHome()
        let movies = openMovies(app)
        let first = app.buttons[firstLibraryTile(app).identifier]
        let title = app.staticTexts[A11yID.TV.Library.title(UITestFixtureIdentity.moviesLibraryID)]
        let titleTop = title.frame.minY
        press(.down, times: 2)
        XCTAssertTrue(poll(timeout: 5) { !title.exists || title.frame.minY < titleTop - 50 }, "The grid scrolled")
        press(.menu)
        XCTAssertTrue(waitForFocus(first), "Menu goes back to the first tile")
        XCTAssertTrue(poll(timeout: 5) { abs(title.frame.minY - titleTop) < 2 }, "…at the grid's top")
        XCTAssertTrue(isCollapsed(movies), "The rail stays collapsed")
        press(.menu)
        XCTAssertTrue(waitForExpanded(movies), "Menu again opens the rail")
    }

    func test_profile_menuOnceScrolled_returnsToSwitchUser_thenOpensTheRail() {
        let app = launchAtHome()
        openRailFromHome(app)
        let profile = app.buttons[A11yID.TV.Sidebar.profile]
        press(.up)
        XCTAssertTrue(waitForFocus(profile))
        press(.select)
        let switchUser = app.buttons[A11yID.TV.Profile.switchUser]
        XCTAssertTrue(waitForFocus(switchUser))
        let top = switchUser.frame.minY
        pressDown(until: app.buttons[A11yID.TV.Profile.privacyPolicy], presses: 16)
        press(.menu)
        XCTAssertTrue(waitForFocus(switchUser), "Menu goes back to Switch User")
        XCTAssertTrue(poll(timeout: 5) { abs(switchUser.frame.minY - top) < 2 }, "…at the top")
        XCTAssertTrue(isCollapsed(profile), "The rail stays collapsed")
        press(.menu)
        XCTAssertTrue(waitForExpanded(profile), "Menu again opens the rail")
    }

    func test_search_menuFromAResult_returnsToTheKeyboard_thenOpensTheSidebar() {
        let app = launchAtHome()
        openRailFromHome(app)
        let row = app.buttons[A11yID.TV.Sidebar.search]
        press(.down)
        XCTAssertTrue(waitForFocus(row))
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Quiet")
        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        for _ in 0..<5 where !result.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(result))
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !result.hasFocus }, "Focus leaves the results")
        XCTAssertFalse(waitForExpanded(row, timeout: 2), "…for the keyboard, not the sidebar")
        // With the keyboard focused the field's value carries the system's
        // dictation hint after the query.
        XCTAssertTrue((field.value as? String)?.hasPrefix("Quiet") == true, "The query is kept")
        press(.menu)
        XCTAssertTrue(waitForExpanded(row), "Menu again slides the sidebar in")
    }
}
