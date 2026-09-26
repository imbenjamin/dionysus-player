import XCTest

/// Deeper coverage of the welcome → `.serverSetup` → `.login` → `.main`
/// journey than `SmokeJourneyTests.testFirstRunSetupAndSignIn` exercises —
/// that one test stays a single happy path on purpose (fast PR feedback); the
/// error and backtrack branches belong here instead, in the full plan only.
final class AuthJourneyTests: UITestCase {
    // MARK: - Welcome

    /// A first launch opens on the welcome, and "Get Started" leads to server
    /// setup — where a scan has already started by itself.
    func testFirstLaunchWelcomesThenFindsServers() {
        launch(signedIn: false, skipsWelcome: false)

        let welcome = WelcomeScreen(app: app)
        welcome.awaitLoaded()
        XCTAssertTrue(welcome.jellyfinLink.exists, "The welcome should say what Jellyfin is, for anyone without a server.")
        welcome.getStarted()

        ServerSetupScreen(app: app).scanForStubServer()
    }

    /// Once past, the welcome stays past: a relaunch still in server setup
    /// goes straight there.
    func testWelcomeIsShownOnlyOnce() {
        launch(signedIn: false, skipsWelcome: false)
        WelcomeScreen(app: app).getStarted()
        ServerSetupScreen(app: app).awaitLoaded()
        app.terminate()

        launch(signedIn: false, resetsState: false, skipsWelcome: false)
        ServerSetupScreen(app: app).awaitLoaded()
        XCTAssertFalse(WelcomeScreen(app: app).getStartedButton.exists)
    }

    // MARK: - Server setup

    /// `ServerConfiguration.parse` rejects this before any request goes out
    /// — a bare scheme has no host — so this exercises client-side
    /// validation, not the stub.
    func testInvalidServerAddressShowsAnError() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.connect(to: "http://")

        serverSetup.errorMessage.awaitExistence("the server setup error message")
    }

    /// A server found while the scan is still running is listed at once, and
    /// the screen still says it's searching — then stops saying so once the
    /// scan is done.
    func testServersFoundMidScanShowTheScanIsStillRunning() {
        launch(scenario: "slowScan", signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.scanningIndicator.awaitExistence("the still-searching indicator")
        XCTAssertFalse(serverSetup.scanButton.exists, "Scan Again shouldn't be offered mid-scan.")
    }

    func testTheSearchingIndicatorGoesOnceTheScanFinishes() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.scanButton.awaitExistence("the Scan Again button")
        XCTAssertFalse(serverSetup.scanningIndicator.exists)
    }

    /// Picking the server the arrival scan found connects exactly as typing
    /// its address would — through the stub's `/System/Info/Public` — landing
    /// on sign-in with no typing at all.
    func testPickingAScannedServerReachesLogin() {
        launch(signedIn: false)

        ServerSetupScreen(app: app).scanForStubServer().tap()

        LoginScreen(app: app).awaitLoaded()
    }

    /// A discovered HTTPS server whose certificate fails (the stub rejects every
    /// `https://` request) but which answers over HTTP asks before connecting
    /// unencrypted, and accepting lands on sign-in.
    func testAcceptingTheHTTPFallbackForAnUnverifiableServerReachesLogin() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.discoveredServer(UITestFixtureIdentity.serverSystemID).tap()

        serverSetup.insecureFallbackConfirmButton.awaitExistence("the connect-over-HTTP button")
        serverSetup.insecureFallbackConfirmButton.tap()

        LoginScreen(app: app).awaitLoaded()
    }

    /// With nothing on the default HTTP port, the fallback asks which port the
    /// server's HTTP is on, then offers the same confirmation for that port.
    func testHTTPFallbackAsksForTheHTTPPortWhenTheDefaultIsSilent() {
        launch(scenario: "customHTTPPort", signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.discoveredServer(UITestFixtureIdentity.serverSystemID).tap()

        serverSetup.httpPortField.awaitExistence("the HTTP port field")
        serverSetup.httpPortField.tap()
        serverSetup.httpPortField.typeText("8097")
        serverSetup.httpPortConfirmButton.tap()

        serverSetup.insecureFallbackConfirmButton.awaitExistence("the connect-over-HTTP button")
        serverSetup.insecureFallbackConfirmButton.tap()

        LoginScreen(app: app).awaitLoaded()
    }

    /// Cancelling the same prompt stays on server setup, explained, with the
    /// scan results still there to pick another.
    func testCancellingTheHTTPFallbackStaysOnServerSetup() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.discoveredServer(UITestFixtureIdentity.serverSystemID).tap()

        serverSetup.insecureFallbackCancelButton.awaitExistence("the cancel button")
        serverSetup.insecureFallbackCancelButton.tap()

        serverSetup.errorMessage.awaitExistence("the certificate explanation")
        XCTAssertTrue(
            serverSetup.discoveredServer(UITestFixtureIdentity.discoveredServerID).exists,
            "The other scan results should still be there to pick from."
        )
    }

    /// The HTTPS toggle decides how a bare address is connected to, so it has
    /// to stay reachable while one is typed. It lives in the address sheet
    /// with the field, and the sheet rises above the keyboard.
    ///
    /// Needs the software keyboard; a simulator with "Connect Hardware
    /// Keyboard" on never shows one, so the test skips rather than passing on
    /// nothing.
    func testTheHTTPSToggleStaysAboveTheKeyboardWhileTyping() throws {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.openAddressSheet()
        serverSetup.addressField.tap()

        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            throw XCTSkip("No software keyboard on this simulator.")
        }

        let toggle = serverSetup.httpsToggle
        let clear = NSPredicate { _, _ in toggle.exists && toggle.frame.maxY <= keyboard.frame.minY }
        let settled = XCTNSPredicateExpectation(predicate: clear, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 5), .completed,
            "The HTTPS toggle (maxY \(toggle.frame.maxY)) should sit above the keyboard (minY \(keyboard.frame.minY))."
        )
        XCTAssertTrue(toggle.isHittable)
    }

    /// Cancelling the address sheet returns to the scan results.
    func testCancellingTheAddressSheetKeepsTheScanResults() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer()
        serverSetup.openAddressSheet()
        serverSetup.addressSheetCancelButton.tap()

        XCTAssertTrue(
            serverSetup.addressField.waitForNonExistence(timeout: UITestCase.defaultTimeout),
            "Cancel should close the address sheet."
        )
        XCTAssertTrue(serverSetup.discoveredServer(UITestFixtureIdentity.discoveredServerID).exists)
    }

    // MARK: - Sign-in

    /// A user without a password signs in with one tap on their avatar.
    func testPasswordlessUserSignsInWithOneTap() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).scanForStubServer().tap()

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.userTile(UITestFixtureIdentity.passwordlessUserID).tap()

        HomeScreen(app: app).awaitLoaded()
    }

    /// The stub fails `/Users/AuthenticateByName` itself when the posted
    /// password doesn't match the fixture credential (see
    /// `UITestStubURLProtocol.suppliesTheFixturePassword`) — a real 401
    /// reaching `LoginViewModel`, not a client-side check.
    func testWrongPasswordShowsAnErrorAndKeepsTheUserChosen() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.signIn(password: "definitely-wrong")

        login.errorMessage.awaitExistence("the login error message")
        XCTAssertTrue(login.passwordField.exists, "The password should still be asked for, for another try.")
    }

    /// The server's disclaimer shows under the grid, its `<br/>` turned into a
    /// line break rather than shown as markup.
    func testTheServersDisclaimerIsShownAsPlainText() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.disclaimer.awaitExistence("the server's disclaimer")
        XCTAssertFalse(login.disclaimer.label.contains("<br"), "Markup should be stripped: \(login.disclaimer.label)")
    }

    /// Someone the server doesn't list signs in by name from "Other".
    func testOtherUserSignsInByName() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.openOtherUser()
        login.signInManually(username: UITestFixtureIdentity.username, password: UITestFixtureIdentity.password)

        HomeScreen(app: app).awaitLoaded()
    }

    /// Every user hidden from the login screen: a plain username and password
    /// form instead of an empty grid.
    func testHiddenUsersFallBackToTheSignInForm() {
        launch(scenario: "hiddenUsers", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.signInManually(username: UITestFixtureIdentity.username, password: UITestFixtureIdentity.password)

        HomeScreen(app: app).awaitLoaded()
    }

    // MARK: - Quick Connect

    /// Quick Connect end to end: offered under "Other", the sheet shows the
    /// code the server issued, and once the stub approves it on the first poll
    /// the app signs in without a username or password ever being typed.
    func testQuickConnectSignsIn() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        LoginScreen(app: app).openQuickConnect()

        QuickConnectScreen(app: app).awaitCode(UITestFixtureIdentity.quickConnectCode(1))
        HomeScreen(app: app).awaitLoaded()
    }

    /// A Quick Connect session has no password, so launch restores it by
    /// checking its token (`GET /Users/Me`) rather than signing in again. A
    /// relaunch that fell back to the password path would post an empty
    /// password, which the stub refuses, and land on sign-in instead.
    func testQuickConnectSessionSurvivesRelaunch() {
        testQuickConnectSignsIn()
        app.terminate()

        launch(signedIn: false, resetsState: false)
        HomeScreen(app: app).awaitLoaded()
    }

    /// An expired code (Jellyfin's 404, after 10 minutes) offers a new one,
    /// and the new one signs in.
    func testExpiredQuickConnectCodeCanBeReplaced() {
        launch(scenario: "quickConnectExpiring", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        LoginScreen(app: app).openQuickConnect()

        let quickConnect = QuickConnectScreen(app: app)
        quickConnect.newCodeButton.awaitExistence("the Get New Code button")
        quickConnect.errorMessage.awaitExistence("the expiry message")
        quickConnect.newCodeButton.tap()

        quickConnect.awaitCode(UITestFixtureIdentity.quickConnectCode(2))
        HomeScreen(app: app).awaitLoaded()
    }

    /// Cancelling the sheet returns to the user grid, still signed out.
    func testCancellingQuickConnectReturnsToLogin() {
        launch(scenario: "quickConnectPending", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.openQuickConnect()

        let quickConnect = QuickConnectScreen(app: app)
        quickConnect.awaitCode(UITestFixtureIdentity.quickConnectCode(1))
        quickConnect.cancelButton.tap()

        XCTAssertTrue(
            quickConnect.code.waitForNonExistence(timeout: UITestCase.defaultTimeout),
            "Cancel should close the Quick Connect sheet."
        )
        XCTAssertTrue(login.fixtureUserTile.exists, "Cancelling should leave the user grid on screen.")
    }

    /// A server with Quick Connect turned off gets no button for it.
    func testQuickConnectIsHiddenWhenTheServerDisablesIt() {
        launch(scenario: "quickConnectDisabled", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.openOtherUser()
        // The stub answers `/QuickConnect/Enabled` immediately, before the
        // grid this sheet was opened from had even appeared.
        XCTAssertFalse(
            login.quickConnectButton.waitForExistence(timeout: 3),
            "Sign-in shouldn't offer Quick Connect on a server that has it turned off."
        )
    }

    // MARK: - Backtracking

    /// "Change Server" discards the server configuration and returns to server
    /// setup — the backtrack `AppState.changeServer()` drives, reachable
    /// without ever having signed in — and never back to the welcome.
    func testChangingServerFromLoginReturnsToServerSetup() {
        launch(signedIn: false, skipsWelcome: false)
        WelcomeScreen(app: app).getStarted()
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.changeServerButton.tap()

        ServerSetupScreen(app: app).awaitLoaded()
        XCTAssertFalse(WelcomeScreen(app: app).getStartedButton.exists, "Changing server shouldn't replay the welcome.")
    }
}
