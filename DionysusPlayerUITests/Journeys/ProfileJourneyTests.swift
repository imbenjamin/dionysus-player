import XCTest

/// Profile coverage: the two destructive account actions reachable through
/// the account card (`ProfileScreen`'s doc comment explains why this
/// stays scoped to just those — the rest of Profile forks by device in a
/// way this suite doesn't yet absorb).
final class ProfileJourneyTests: UITestCase {
    /// Approving another device's code signs it in and says so.
    func testQuickConnectApprovesACode() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectApprovableCode)

        quickConnect.successMessage.awaitExistence("the signed-in confirmation")
        quickConnect.doneButton.tap()
        XCTAssertTrue(
            ProfileScreen(app: app).quickConnectRow.waitForExistence(timeout: UITestCase.defaultTimeout),
            "Done should return to the Account screen."
        )
    }

    /// A wrong code (404) explains itself and leaves the field editable, and
    /// the right code then goes through.
    func testWrongQuickConnectCodeCanBeCorrected() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: "000000")
        quickConnect.errorMessage.awaitExistence("the wrong-code message")

        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectApprovableCode)
        quickConnect.successMessage.awaitExistence("the signed-in confirmation")
    }

    /// Jellyfin's 500 for an already-approved code reaches the user as an
    /// explanation, not a generic failure or a dead screen.
    func testAlreadyUsedQuickConnectCodeShowsAnError() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectUsedCode)

        quickConnect.errorMessage.awaitExistence("the already-used message")
        XCTAssertFalse(quickConnect.successMessage.exists)
    }

    /// No row at all when the server has Quick Connect turned off.
    func testQuickConnectRowHiddenWhenTheServerDisablesIt() {
        launch(scenario: "quickConnectDisabled")
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let profile = ProfileScreen(app: app)
        profile.openAccountDetails()
        app.buttons[A11yID.Profile.signOutButton].awaitExistence("the Sign Out row")
        // `/QuickConnect/Enabled` answers immediately under the stub, so a
        // row that was going to appear would have by now.
        XCTAssertFalse(
            profile.quickConnectRow.waitForExistence(timeout: 3),
            "Account shouldn't offer Quick Connect on a server that has it turned off."
        )
    }

    func testSignOutReturnsToLogin() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        ProfileScreen(app: app).signOut()

        LoginScreen(app: app).awaitLoaded()
    }

    /// Distinct from `AuthJourneyTests.testChangingServerFromLoginReturnsToServerSetup`,
    /// which reaches the same `AppState.changeServer()` from Login instead
    /// — this is the other entry point, reachable while already signed in.
    func testChangeServerFromProfileReturnsToServerSetup() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        ProfileScreen(app: app).changeServer()

        ServerSetupScreen(app: app).awaitLoaded()
    }
}
