import XCTest

/// The fallback for tvOS user switching: an account signed in on this Apple TV
/// is remembered, so Switch User then one press on that account returns to
/// Home, with no code and no password.
final class AccountSwitchingJourneyTests: TVUITestCase {
    private var remembered: XCUIElement {
        XCUIApplication().buttons[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.userID)]
    }

    func test_switchUser_thenRememberedAccount_signsBackInOnOnePress() {
        let app = switchUser()
        XCTAssertTrue(waitForFocus(remembered), "The most recent remembered account takes first focus")
        XCTAssertFalse(
            app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)].exists,
            "A remembered account is listed once"
        )
        press(.select)
        let play = app.buttons[A11yID.TV.Main.heroPlay]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "No code and no password: straight to Home")
        XCTAssertTrue(waitForFocus(play))
    }

    /// Holding Select offers to forget the account. It then goes back among
    /// the server's users, where choosing it asks for a code again.
    func test_forgetAccount_putsItBackAmongTheServersUsers() {
        let app = switchUser()
        XCTAssertTrue(waitForFocus(remembered))
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        // The system menu's row isn't a button to XCUITest, and its cell, not
        // the row, is what has focus.
        let forget = app.descendants(matching: .any)[A11yID.TV.Onboarding.forgetAccount]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        press(.select)

        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        XCTAssertFalse(remembered.exists)
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10))
    }

    /// Turned off, the session moves to the keychain every Apple TV user
    /// shares, and whoever is signed in stays signed in across a relaunch.
    func test_followAppleTVUsersOff_keepsTheSignedInAccountAcrossRelaunch() {
        let app = openProfile(launchAtHome())
        let toggle = app.descendants(matching: .any)[A11yID.TV.Profile.followsAppleTVUsers]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "On by default")
        press(.down, times: 2)
        XCTAssertTrue(waitForFocus(toggle))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { toggle.value as? String == "0" })

        app.terminate()
        let relaunched = launch(resetsState: false)
        XCTAssertTrue(relaunched.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10), "Still signed in, from the shared keychain")
        let relaunchedToggle = openProfile(relaunched).descendants(matching: .any)[A11yID.TV.Profile.followsAppleTVUsers]
        XCTAssertTrue(relaunchedToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(relaunchedToggle.value as? String, "0", "The setting is kept too")
    }

    /// Sharing one session with two accounts remembered: a relaunch starts at
    /// Who's Watching?, the last account used first, and one press signs in.
    /// The setting that asks appears only once Follow Apple TV Users is off.
    func test_followOff_withTwoAccounts_aRelaunchAsksWhoIsWatching() {
        // A second account: Switch User, then the passwordless Guest.
        var app = switchUser()
        let guest = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        press(.right)
        XCTAssertTrue(waitForFocus(guest))
        press(.select)

        app = openProfile(app)
        let follows = app.descendants(matching: .any)[A11yID.TV.Profile.followsAppleTVUsers]
        let selects = app.descendants(matching: .any)[A11yID.TV.Profile.selectsUserEveryRelaunch]
        XCTAssertTrue(follows.waitForExistence(timeout: 10))
        XCTAssertFalse(selects.exists, "Nothing to choose while each Apple TV user has their own session")
        press(.down, times: 2)
        XCTAssertTrue(waitForFocus(follows))
        press(.select)
        XCTAssertTrue(selects.waitForExistence(timeout: 5))
        XCTAssertEqual(selects.value as? String, "1", "On by default")

        app.terminate()
        let relaunched = launch(scenario: "quickConnectPending", resetsState: false)
        XCTAssertTrue(relaunched.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        let lastUsed = relaunched.buttons[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(waitForFocus(lastUsed), "The account last used takes focus")
        XCTAssertTrue(remembered.exists)
        press(.select)
        XCTAssertTrue(relaunched.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
    }

    /// From Home to Profile, with Switch User focused.
    private func openProfile(_ app: XCUIApplication) -> XCUIApplication {
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 10))
        openRailFromHome(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.profile]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.switchUser]), "Switch User takes focus on Profile")
        return app
    }

    /// Signed in, then Profile's Switch User: on Who's Watching?.
    private func switchUser() -> XCUIApplication {
        let app = openProfile(launchAtHome(scenario: "quickConnectPending"))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(remembered.waitForExistence(timeout: 10))
        return app
    }
}
