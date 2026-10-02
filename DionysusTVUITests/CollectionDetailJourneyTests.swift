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
