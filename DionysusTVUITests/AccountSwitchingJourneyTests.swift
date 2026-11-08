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

    /// A remembered account says it's signed in (its checkmark is drawn, not
    /// read); one of the server's other users says nothing.
    func test_rememberedAccount_saysItIsSignedIn() {
        let app = switchUser()
        XCTAssertTrue(remembered.waitForExistence(timeout: 10))
        let listed = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(listed.waitForExistence(timeout: 5))
        XCTAssertFalse((remembered.value as? String ?? "").isEmpty, "Remembered: has a value")
        XCTAssertTrue((listed.value as? String ?? "").isEmpty, "Listed: none")
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
        // The values read "On"/"Off", which are localized: the setting is
        // read from Select a User Every Relaunch, there only while it's off.
        let follows = app.buttons[A11yID.TV.Profile.followsAppleTVUsers]
        let selects = app.buttons[A11yID.TV.Profile.selectsUserEveryRelaunch]
        XCTAssertTrue(follows.waitForExistence(timeout: 10))
        XCTAssertFalse(selects.exists, "On by default")
        let before = follows.value as? String
        pressDown(until: follows)
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (follows.value as? String) != before })
        XCTAssertTrue(selects.waitForExistence(timeout: 5))

        app.terminate()
        let relaunched = launch(resetsState: false)
        XCTAssertTrue(relaunched.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10), "Still signed in, from the shared keychain")
        let relaunchedSelects = openProfile(relaunched).buttons[A11yID.TV.Profile.selectsUserEveryRelaunch]
        XCTAssertTrue(relaunchedSelects.waitForExistence(timeout: 10), "The setting is kept too")
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
        let follows = app.buttons[A11yID.TV.Profile.followsAppleTVUsers]
        let selects = app.buttons[A11yID.TV.Profile.selectsUserEveryRelaunch]
        XCTAssertTrue(follows.waitForExistence(timeout: 10))
        XCTAssertFalse(selects.exists, "Nothing to choose while each Apple TV user has their own session")
        pressDown(until: follows)
        press(.select)
        XCTAssertTrue(selects.waitForExistence(timeout: 5))
        // Values are localized: with Follow now off, an equal value is On.
        XCTAssertTrue(poll(timeout: 5) { (selects.value as? String) != (follows.value as? String) }, "On by default")

        app.terminate()
        let relaunched = launch(scenario: "quickConnectPending", resetsState: false)
        XCTAssertTrue(relaunched.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        let lastUsed = relaunched.buttons[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(waitForFocus(lastUsed), "The account last used takes focus")
        XCTAssertTrue(remembered.exists)
        press(.select)
        XCTAssertTrue(relaunched.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
    }

    // MARK: - Remembered accounts the server refuses, and Quick Connect ones (TQ-10)

    /// An account signed in through Quick Connect is remembered with its
    /// token, not a password: one press checks the token and signs in, with
    /// no new code. Relaunched where no code is ever approved, so a press
    /// that asked for one would stay on it.
    func test_rememberedQuickConnectAccount_signsBackInOnOnePress() {
        signInThroughQuickConnect().terminate()
        let app = launch(scenario: "quickConnectPending", resetsState: false)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10), "Launch resumes the session from its token")
        _ = openProfile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(remembered), "The Quick Connect account is remembered")
        press(.select)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10), "Its token signs it back in")
        XCTAssertFalse(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].exists, "No new code")
    }

    /// A remembered Quick Connect account whose token the server now refuses
    /// has no password to ask for: one press asks for a new code instead, and
    /// approving it signs in.
    func test_refusedQuickConnectAccount_asksForANewCode() {
        signInThroughQuickConnect().terminate()
        // Launch checks the token too, is refused, and lands on Who's Watching?.
        let app = launch(scenario: "revokedSessions", resetsState: false)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(remembered, timeout: 10), "Still remembered after the refusal")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10), "A new code")
        XCTAssertFalse(app.secureTextFields[A11yID.TV.Onboarding.passwordField].exists, "Not a password")
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15), "Approved, it signs in")
    }

    /// A remembered password account the server now refuses (the password
    /// was changed) opens its password screen, saying why.
    func test_refusedPasswordAccount_opensItsPasswordScreen_sayingWhy() {
        // The seeded session is refused at launch, which lands here with the
        // account still remembered.
        let app = launch(scenario: "revokedSessions", seedSession: true)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(remembered, timeout: 10))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 10), "Its password screen")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.signInError].waitForExistence(timeout: 5), "The refusal is explained")
        XCTAssertFalse(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].exists, "Not a Quick Connect code")
        XCTAssertFalse(app.buttons[A11yID.TV.Main.heroPlay].exists, "Not signed in")
    }

    /// From a fresh launch: the discovered server, then the user with a
    /// password, who goes to Quick Connect; the stub approves the first poll.
    private func signInThroughQuickConnect() -> XCUIApplication {
        let app = launch()
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server))
        press(.select)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15))
        return app
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
