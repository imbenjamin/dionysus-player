import XCTest

/// Box set and playlist pages: a box set's movies open their own detail
/// pages; a playlist's rows play.
final class CollectionDetailJourneyTests: TVUITestCase {
    /// Chooses a library from the rail and opens one of its tiles.
    private func open(_ itemID: String, inLibrary libraryID: String, _ app: XCUIApplication) -> XCUIElement {
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(libraryID)])
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(itemID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)))
        for _ in 0..<6 where !tile.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(tile))
        press(.select)
        return tile
    }

    private func members(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.member."))
    }

    /// A box set lists its movies; each opens its own detail page, and Menu
    /// comes back to the box set, then to the library.
    func test_boxSet_listsItsMovies_andEachOpensItsDetailPage() {
        let app = launchAtHome()
        let tile = open(UITestFixtureIdentity.boxSetID, inLibrary: UITestFixtureIdentity.boxSetsLibraryID, app)
        let first = members(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(first), "A box set has no Play button: focus starts on its first movie")
        XCTAssertGreaterThan(members(app).count, 1)
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.menu)
        XCTAssertTrue(waitForFocus(first))
        press(.menu)
        XCTAssertTrue(waitForFocus(tile))
    }

    /// Menu while a page is still loading pops it (the M3 review's Review
    /// Focus 5): the page keeps focus on its loading indicator, so the
    /// sidebar's three-second fallback never opens over it and Menu, which
    /// reaches nothing while nothing has focus, still has somewhere to go.
    func test_menuWhileABoxSetLoads_popsBackToItsTile() {
        let app = launchAtHome(scenario: "slowBoxSet")
        let tile = open(UITestFixtureIdentity.boxSetID, inLibrary: UITestFixtureIdentity.boxSetsLibraryID, app)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Detail.loading].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.buttons[A11yID.TV.Sidebar.home].hasFocus || app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.boxSetsLibraryID)].hasFocus,
                       "The sidebar stays shut over a loading page")
        press(.menu)
        XCTAssertTrue(waitForFocus(tile), "Menu pops the loading page")
    }

    /// Once the members land, focus moves from the loading indicator to
    /// the first of them.
    func test_aBoxSetThatLoadsSlowly_focusesItsFirstMovieOnceLoaded() {
        let app = launchAtHome(scenario: "slowBoxSet")
        _ = open(UITestFixtureIdentity.boxSetID, inLibrary: UITestFixtureIdentity.boxSetsLibraryID, app)
        XCTAssertTrue(waitForFocus(app.descendants(matching: .any)[A11yID.TV.Detail.loading]))
        XCTAssertTrue(members(app).firstMatch.waitForExistence(timeout: 30), "The members land")
        XCTAssertTrue(waitForFocus(members(app).firstMatch), "and the first takes focus")
    }

    /// A playlist plays from its Play button and from any row.
    func test_playlist_playsFromPlay_andFromARow() {
        let app = launchAtHome()
        _ = open(UITestFixtureIdentity.playlistID, inLibrary: UITestFixtureIdentity.playlistsLibraryID, app)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        press(.select)
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !elapsed.exists })
        XCTAssertTrue(waitForFocus(play))

        press(.down)
        let first = members(app).firstMatch
        XCTAssertTrue(waitForFocus(first))
        press(.select)
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "A playlist's row plays; it doesn't open a detail page")
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !elapsed.exists })
        XCTAssertTrue(first.exists, "Back on the playlist")
    }

    /// The fixture's Late Night playlist ships empty.
    func test_emptyPlaylist_showsAMessage_andMenuPops() {
        let app = launchAtHome()
        let tile = open(UITestFixtureIdentity.secondPlaylistID, inLibrary: UITestFixtureIdentity.playlistsLibraryID, app)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Detail.emptyMessage].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].exists, "No Play button with nothing to play")
        press(.menu)
        XCTAssertTrue(waitForFocus(tile))
    }
}
