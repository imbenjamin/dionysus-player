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

    /// Nothing typed and nothing opened yet: iOS's "Search Your Library"
    /// placeholder (Benjamin, 2026-10-04), gone once there is a recent search.
    func test_emptyHistory_showsThePlaceholder() {
        let app = launchAtHome()
        _ = openSearch(app)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.emptyHistory].waitForExistence(timeout: 5)
            || app.otherElements[A11yID.TV.Search.emptyHistory].exists)
    }

    /// Another page chosen from the sidebar, then Search again: a fresh
    /// page, the field empty and the results gone (Benjamin, 2026-10-04).
    func test_leavingForAnotherPage_andComingBack_startsFresh() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("Quiet")
        let result = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(result.waitForExistence(timeout: 10))

        press(.menu)
        let search = app.buttons[A11yID.TV.Sidebar.search]
        XCTAssertTrue(waitForFocus(search))
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]))

        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(search))
        press(.select)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Search.emptyHistory].waitForExistence(timeout: 5), "Search starts fresh")
        XCTAssertFalse(result.exists, "…with the last query's results gone")
    }

    func test_noResults_saysSo() {
        let app = launchAtHome()
        let field = openSearch(app)
        field.typeText("zzzzzz")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.noResults].waitForExistence(timeout: 10))
    }

    /// An opened result becomes a recent search, shown while the field is
    /// empty under its type's rail, as results are (Benjamin, 2026-10-04),
    /// and Clear, beside the heading, removes it.
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

        // Back on Search with the query still there: empty it.
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        press(.up, times: 3)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        let recent = app.buttons[A11yID.TV.Search.recent(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "With the field empty, what was opened is listed")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Search.recentSection("movies")].exists, "…under its type's rail")

        let clear = app.buttons[A11yID.TV.Search.clearRecent]
        focus(recent)
        press(.up)
        XCTAssertTrue(waitForFocus(clear), "Clear sits beside the heading, above the rails")
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { !recent.exists })
    }

    /// Search is the system's full-screen layout (Benjamin, 2026-10-04): the
    /// collapsed rail slides off the left edge, so the field starts at the
    /// screen's own margin and ends inside it.
    func test_search_isFullScreen_withTheRailOffScreen() {
        let app = launchAtHome()
        let field = openSearch(app)
        let row = app.buttons[A11yID.TV.Sidebar.search]
        XCTAssertTrue(poll(timeout: 5) { !row.exists || row.frame.maxX <= 0 }, "The collapsed rail is off screen")
        XCTAssertLessThan(field.frame.minX, 150, "The field starts at the screen's margin, not beside a rail")
        XCTAssertLessThanOrEqual(field.frame.maxX, app.frame.maxX - 40, "…and ends inside the screen")
    }

    /// Menu slides the sidebar in, open on Search's row; back to the page,
    /// it slides away again.
    func test_menu_slidesTheSidebarIn_andRightSendsItAway() {
        let app = launchAtHome()
        _ = openSearch(app)
        let row = app.buttons[A11yID.TV.Sidebar.search]
        press(.menu)
        XCTAssertTrue(waitForFocus(row))
        XCTAssertTrue(waitForExpanded(row))
        XCTAssertGreaterThanOrEqual(row.frame.minX, 0, "The open sidebar is on screen")
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { !row.exists || row.frame.maxX <= 0 }, "Collapsed again, the rail is off screen")
    }
}
