import XCTest

/// Getting around the signed-in shell: the rail is always on screen, and its
/// width tells whether it's open (72pt icon circles collapsed, full-width
/// pill rows open).
extension TVUITestCase {
    /// Signed in, on Home, with focus on its first tile.
    func launchAtHome(scenario: String = "standard") -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        let firstTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstTile))
        return app
    }

    func isCollapsed(_ row: XCUIElement) -> Bool { row.exists && row.frame.width < 100 }

    /// Waits for the rail to open: it widens as focus enters it.
    func waitForExpanded(_ row: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) { row.exists && row.frame.width > 300 }
    }

    /// Waits for the rail to close again after focus leaves it.
    func waitForCollapsed(_ row: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) { self.isCollapsed(row) }
    }

    /// `frame` can't be read through an `NSPredicate` key path (it never
    /// matches), so geometry is polled.
    func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        attachTree()
        return false
    }

    /// Left from the page opens the rail on Home's row.
    func openRailFromHome(_ app: XCUIApplication) {
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.home]))
    }

    /// Chooses a library in the standard scenario, where Movies is the row
    /// below Search, and waits for its first tile to take focus.
    func openMovies(_ app: XCUIApplication) -> XCUIElement {
        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        let movies = app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)]
        press(.down)
        XCTAssertTrue(waitForFocus(movies))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Library.title(UITestFixtureIdentity.moviesLibraryID)].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)), "The first tile takes focus when the library opens")
        return movies
    }

    func firstLibraryTile(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
    }

    /// Presses Down until `element` has focus, up to a sidebar's worth,
    /// letting focus settle after each press: read straight after one, focus
    /// still sits on the row before and the loop overshoots.
    func pressDown(until element: XCUIElement) {
        for _ in 0..<10 {
            if element.hasFocus { break }
            press(.down)
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 1)
        }
        XCTAssertTrue(waitForFocus(element))
    }

    /// A tile opens its detail page, with focus on Play (or Resume).
    @discardableResult
    func openDetailFromFocusedTile(_ app: XCUIApplication) -> XCUIElement {
        press(.select)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play), "A detail page opens with focus on Play")
        return play
    }

    /// Tile, then Play on its detail page: the way to the player since M3.
    func playFromFocusedTile(_ app: XCUIApplication) {
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
    }
}
