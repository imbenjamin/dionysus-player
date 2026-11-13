import XCTest

/// Getting through onboarding.
extension TVUITestCase {
    /// From server setup: Select on the discovered stub server, which takes
    /// default focus, then wait for Who's Watching?.
    func connectToDiscoveredServer(_ app: XCUIApplication) {
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server), "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }
}
