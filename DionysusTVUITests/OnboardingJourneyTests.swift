import XCTest

final class OnboardingJourneyTests: TVUITestCase {
    /// Discovery lists the stub server with default focus on it, so one Select
    /// connects; the stub's public user list then shows, and choosing the
    /// passwordless user (second in the list, after one with a password) signs
    /// straight in.
    func test_selectDiscoveredServer_thenUser_reachesMain() {
        let app = launch()
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[A11yID.TV.Sidebar.home].exists, "No rail before signing in")
        press(.right)
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let main = app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10)
        if !main { attachTree() }
        XCTAssertTrue(main)
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Signed in, the rail is there, collapsed")
    }

    /// Above five lockups the row scrolls, so the first one, which takes
    /// focus, and "Other" at the far end are each fully on screen when focused.
    func test_manyUsers_theRowScrolls_soEveryLockupIsReachable() {
        let app = launch(scenario: "manyUsers")
        connectToDiscoveredServer(app)
        let window = app.windows.firstMatch.frame
        let first = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(first, timeout: 10))
        XCTAssertGreaterThanOrEqual(first.frame.minX, 0, "The first lockup isn't cut off at the left edge")
        let other = app.buttons[A11yID.TV.Onboarding.otherUser]
        for _ in 0..<8 where !other.hasFocus {
            press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(waitForFocus(other))
        XCTAssertLessThanOrEqual(other.frame.maxX, window.maxX, "Other is fully on screen once focused")
    }

    /// Typing an address is the secondary route: a button below the found
    /// servers reveals the field.
    func test_enterServerAddress_revealsTheAddressField() {
        let app = launch()
        let enter = app.buttons[A11yID.TV.Onboarding.enterAddress]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        for _ in 0..<4 where !enter.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(enter))
        press(.select)
        XCTAssertTrue(app.textFields[A11yID.TV.Onboarding.addressField].waitForExistence(timeout: 5))
    }

    /// A user with a password goes to Quick Connect, not a keyboard; the stub
    /// approves the code on its first poll, which signs in.
    func test_passwordUser_signsInThroughQuickConnect() {
        let app = launch()
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15))
    }

    /// "Use Password Instead" is one press from the code, and opens a password
    /// field for the chosen user.
    func test_quickConnect_usePasswordInstead_showsThePasswordField() {
        let app = launch(scenario: "quickConnectPending")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let usePassword = app.buttons[A11yID.TV.Onboarding.usePassword]
        XCTAssertTrue(usePassword.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(usePassword))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    /// With Quick Connect off, a user with a password goes straight to the
    /// password field.
    func test_quickConnectDisabled_passwordUser_goesStraightToPassword() {
        let app = launch(scenario: "quickConnectDisabled")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    private func connectToDiscoveredServer(_ app: XCUIApplication) {
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server), "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }
}
