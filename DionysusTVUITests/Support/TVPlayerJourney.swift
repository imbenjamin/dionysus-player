import XCTest

extension TVUITestCase {
    /// Launches signed in, opens the focused first tile's detail page (the
    /// part-watched movie, resuming at 20:00) and plays it.
    @discardableResult
    func openPlayer(scenario: String = "standard", extraArguments: [String]) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: extraArguments)
        waitForHomeThenFirstTile(app)
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        return app
    }

    /// `TVPlayerFocusID`'s id for what has focus in the player.
    func playerFocus(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)[A11yID.TV.Player.focus].label
    }

    func waitForPlayerFocus(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 5) -> Bool {
        let focused = poll(timeout: timeout) { playerFocus(app) == id }
        if !focused { attachTree() }
        return focused
    }

    func elapsedSeconds(_ app: XCUIApplication) -> Double? {
        Self.seconds(app.staticTexts[A11yID.TV.Player.elapsed].label)
    }

    /// "1:02:03" or "12:34" in seconds.
    nonisolated static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Launches signed in and plays S1:E1 from Home's Continue Watching rail,
    /// where it follows the movie.
    @discardableResult
    func openEpisodeOne(scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: extraArguments)
        waitForHomeThenFirstTile(app)
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]))
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.focus].waitForExistence(timeout: 10))
        return app
    }

    /// Presses `direction` until `element` has focus, at most `limit` times.
    func moveFocus(to element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int) -> Bool {
        for _ in 0..<limit {
            if element.hasFocus { return true }
            press(direction)
        }
        return element.hasFocus
    }
}
