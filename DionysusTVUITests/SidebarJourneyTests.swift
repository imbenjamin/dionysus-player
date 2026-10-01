import XCTest

/// The signed-in shell (prototype screens 5, 6 and 6b; Benjamin, 2026-10-01):
/// a collapsed rail beside every page, opened by Left from the page's
/// leftmost item or by Menu, always on the row of the page on show. Choosing
/// a row opens its page with the rail collapsed again and focus on the page's
/// first item. Rows are selected by identifier; focus is moved only by remote
/// presses.
final class SidebarJourneyTests: TVUITestCase {
    /// Home opens beside the collapsed rail, its content starting right of it.
    func test_home_sitsBesideTheCollapsedRail() {
        let app = launchAtHome()
        let home = app.buttons[A11yID.TV.Sidebar.home]
        XCTAssertTrue(isCollapsed(home))
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertGreaterThanOrEqual(tile.frame.minX, home.frame.maxX, "Content never runs under the rail")
    }

    /// Left from the leftmost tile opens the rail on Home's row, whichever
    /// row is nearest; Right goes back to the page and closes it.
    func test_left_opensTheRailOnTheCurrentPage_andRightReturns() {
        let app = launchAtHome()
        let home = app.buttons[A11yID.TV.Sidebar.home]
        press(.left)
        XCTAssertTrue(waitForFocus(home))
        XCTAssertTrue(waitForExpanded(home))
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]))
        XCTAssertTrue(waitForCollapsed(home))
    }

    /// Left from a lower row lands on Home's row too, not on the row beside it.
    func test_leftFromALowerRow_stillLandsOnTheCurrentPagesRow() {
        let app = launchAtHome()
        press(.down)
        let focusedTile = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.main.tile.")).firstMatch
        XCTAssertTrue(focusedTile.waitForExistence(timeout: 5))
        XCTAssertNotEqual(focusedTile.identifier, A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID))
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
    }

    func test_menu_opensTheRailOnTheCurrentPage() {
        let app = launchAtHome()
        let home = app.buttons[A11yID.TV.Sidebar.home]
        press(.menu)
        XCTAssertTrue(waitForFocus(home))
        XCTAssertTrue(waitForExpanded(home))
    }

    /// Menu with the rail open is left to tvOS, which leaves the app.
    func test_menuWithTheRailOpen_leavesTheApp() {
        let app = launchAtHome()
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
        press(.menu)
        let left = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [left], timeout: 10), .completed)
    }

    /// A library is a page like Home: it opens beside the collapsed rail,
    /// Home is torn down, and Left or Menu opens the rail on its own row.
    func test_library_opensBesideTheRail_andLeftOrMenuReturnsToItsRow() {
        let app = launchAtHome()
        let homeTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        let movies = openMovies(app)
        XCTAssertTrue(waitForCollapsed(movies), "Choosing a page closes the rail")
        XCTAssertTrue(homeTile.waitForNonExistence(timeout: 5), "Only the page on show is built")
        let tile = firstLibraryTile(app)
        XCTAssertGreaterThanOrEqual(tile.frame.minX, movies.frame.maxX, "Content never runs under the rail")

        press(.left)
        XCTAssertTrue(waitForFocus(movies))
        XCTAssertTrue(waitForExpanded(movies))
        press(.right)
        XCTAssertTrue(waitForFocus(tile))
        XCTAssertTrue(waitForCollapsed(movies))
        press(.menu)
        XCTAssertTrue(waitForFocus(movies))
    }

    /// Home again from a library: Home's first tile takes focus.
    func test_choosingHome_fromALibrary_focusesItsFirstTile() {
        let app = launchAtHome()
        let movies = openMovies(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(movies))
        let home = app.buttons[A11yID.TV.Sidebar.home]
        press(.up, times: 1)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.up)
        XCTAssertTrue(waitForFocus(home))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]))
        XCTAssertTrue(waitForCollapsed(home))
    }

    /// Search opens beside the collapsed rail, and Menu opens it on Search's row.
    func test_search_sitsBesideTheRail_andMenuReturnsToItsRow() {
        let app = launchAtHome()
        openRailFromHome(app)
        let search = app.buttons[A11yID.TV.Sidebar.search]
        press(.down)
        XCTAssertTrue(waitForFocus(search))
        press(.select)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForCollapsed(search))
        press(.menu)
        XCTAssertTrue(waitForFocus(search))
    }

    /// Profile sits above Home, reads as "Profile & Settings", and opens the
    /// Profile page beside the rail, where Switch User returns to Who's
    /// Watching.
    func test_profile_isAboveHome_andSwitchUserReturnsToWhosWatching() {
        let app = launchAtHome()
        openRailFromHome(app)
        press(.up)
        let profile = app.buttons[A11yID.TV.Sidebar.profile]
        XCTAssertTrue(waitForFocus(profile))
        XCTAssertEqual(profile.label, "Profile & Settings")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.name].waitForExistence(timeout: 10))
        let switchUser = app.buttons[A11yID.TV.Profile.switchUser]
        XCTAssertTrue(waitForFocus(switchUser))
        XCTAssertTrue(waitForCollapsed(profile))
        press(.menu)
        XCTAssertTrue(waitForFocus(profile), "Menu opens the rail on Profile's row")
        press(.right)
        XCTAssertTrue(waitForFocus(switchUser))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Sidebar.home].exists, "No rail before signing in")
    }

    /// Change Server affects every Apple TV user, so it asks first, with
    /// Cancel focused: Up reaches the confirmation.
    func test_changeServer_asksBeforeForgettingTheServer() {
        let app = launchAtHome()
        openProfile(app)
        let change = app.buttons[A11yID.TV.Profile.changeServer]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        press(.down)
        XCTAssertTrue(waitForFocus(change))
        press(.select)
        let confirm = app.buttons[A11yID.TV.Profile.changeServerConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.hasFocus, "Cancel, not the destructive action, takes focus")
        press(.up)
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }

    /// Above five libraries, one Libraries row stands for them; Select expands
    /// it in place and its libraries open like any other. Collapsed, the rail
    /// shows the Libraries row for the folded library on show, and Menu opens
    /// it on that library's own row.
    func test_manyLibraries_foldIntoTheLibrariesRow_andMenuFindsTheOpenOne() {
        let app = launchAtHome(scenario: "manyLibraries")
        let group = app.buttons[A11yID.TV.Sidebar.librariesGroup]
        let movies = app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)]
        openFoldedLibrary(app, UITestFixtureIdentity.moviesLibraryID)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)), "The first tile takes focus when the library opens")
        XCTAssertTrue(waitForCollapsed(group), "The collapsed rail shows the Libraries row for a folded library")
        XCTAssertFalse(movies.exists, "A folded library has no row of its own in the collapsed rail")
        press(.menu)
        XCTAssertTrue(waitForFocus(movies))
    }

    /// The stub's Documentaries is empty: with nothing on the page to focus,
    /// focus ends on the library's row rather than nowhere, where even Menu
    /// would reach nothing.
    func test_emptyLibrary_leavesFocusOnItsRow() {
        let app = launchAtHome(scenario: "manyLibraries")
        let documentaries = app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.documentariesLibraryID)]
        openFoldedLibrary(app, UITestFixtureIdentity.documentariesLibraryID)
        XCTAssertTrue(waitForFocus(documentaries, timeout: 8))
    }

    private func openFoldedLibrary(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons[A11yID.TV.Sidebar.library(id)]
        openRailFromHome(app)
        let group = app.buttons[A11yID.TV.Sidebar.librariesGroup]
        XCTAssertFalse(row.exists, "Folded libraries stay hidden until the row is expanded")
        pressDown(until: group)
        press(.select)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        pressDown(until: row)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Library.title(id)].waitForExistence(timeout: 10))
    }

    private func openProfile(_ app: XCUIApplication) {
        openRailFromHome(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.profile]))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.name].waitForExistence(timeout: 10))
    }
}
