import XCTest

/// Deeper coverage of the `.serverSetup` → `.login` → `.main` machine than
/// `SmokeJourneyTests.testFirstRunSetupAndSignIn` exercises — that one test
/// stays a single happy path on purpose (fast PR feedback); the error and
/// backtrack branches belong here instead, in the full plan only.
///
/// Signing out is not covered here: it's reached through the Profile tab,
/// which gets its own screen object and journeys in a later PR.
final class AuthJourneyTests: UITestCase {
    /// `ServerConfiguration.parse` rejects this before any request goes out
    /// — a bare scheme has no host — so this exercises client-side
    /// validation, not the stub. Deliberately not a scenario switch: the
    /// point is that the app catches this before the network is even asked.
    func testInvalidServerAddressShowsAnError() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.connect(to: "http://")

        serverSetup.errorMessage.awaitExistence("the server setup error message")
    }

    /// The stub fails `/Users/AuthenticateByName` itself when the posted
    /// password doesn't match the fixture credential (see
    /// `UITestStubURLProtocol.suppliesTheFixturePassword`), independent of
    /// scenario — this is a real 401 reaching `LoginViewModel`, not a
    /// client-side check.
    func testBadCredentialsShowAnError() {
        launch(signedIn: false)

        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.signIn(username: UITestFixtureIdentity.username, password: "definitely-wrong")

        login.errorMessage.awaitExistence("the login error message")
        // Still on Login, not bounced somewhere else.
        XCTAssertTrue(login.usernameField.exists, "A failed sign-in should leave the login form on screen.")
    }

    /// Quick Connect end to end: Login offers it, the sheet shows the code
    /// the server issued, and once the stub approves it on the first poll the
    /// app signs in without a username or password ever being typed.
    func testQuickConnectSignsIn() {
        launch(signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.quickConnectButton.awaitExistence("the Quick Connect button")
        login.quickConnectButton.tap()

        QuickConnectScreen(app: app).awaitCode(UITestFixtureIdentity.quickConnectCode(1))
        HomeScreen(app: app).awaitLoaded()
    }

    /// A Quick Connect session has no password, so launch restores it by
    /// checking its token (`GET /Users/Me`) rather than signing in again. A
    /// relaunch that fell back to the password path would post an empty
    /// password, which the stub refuses, and land on Login instead.
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

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.quickConnectButton.awaitExistence("the Quick Connect button")
        login.quickConnectButton.tap()

        let quickConnect = QuickConnectScreen(app: app)
        quickConnect.newCodeButton.awaitExistence("the Get New Code button")
        quickConnect.errorMessage.awaitExistence("the expiry message")
        quickConnect.newCodeButton.tap()

        quickConnect.awaitCode(UITestFixtureIdentity.quickConnectCode(2))
        HomeScreen(app: app).awaitLoaded()
    }

    /// Cancelling the sheet returns to the login form, still signed out.
    func testCancellingQuickConnectReturnsToLogin() {
        launch(scenario: "quickConnectPending", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.quickConnectButton.awaitExistence("the Quick Connect button")
        login.quickConnectButton.tap()

        let quickConnect = QuickConnectScreen(app: app)
        quickConnect.awaitCode(UITestFixtureIdentity.quickConnectCode(1))
        quickConnect.cancelButton.tap()

        XCTAssertTrue(
            quickConnect.code.waitForNonExistence(timeout: UITestCase.defaultTimeout),
            "Cancel should close the Quick Connect sheet."
        )
        XCTAssertTrue(login.usernameField.exists, "Cancelling should leave the login form on screen.")
    }

    /// A server with Quick Connect turned off gets no button for it.
    func testQuickConnectIsHiddenWhenTheServerDisablesIt() {
        launch(scenario: "quickConnectDisabled", signedIn: false)
        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        // The stub answers `/QuickConnect/Enabled` immediately, so a button
        // that was going to appear would have by now.
        XCTAssertFalse(
            login.quickConnectButton.waitForExistence(timeout: 3),
            "Login shouldn't offer Quick Connect on a server that has it turned off."
        )
    }

    /// Scanning lists the server `UITestServerDiscovery` answers with, and
    /// picking it connects exactly as typing its address would — through the
    /// stub's `/System/Info/Public` — landing on Login with no typing at all.
    func testScanningForServersAndPickingOneReachesLogin() {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        serverSetup.scanForStubServer().tap()

        LoginScreen(app: app).awaitLoaded()
    }

    /// A discovered HTTPS server whose certificate fails (the stub rejects every
    /// `https://` request) but which answers over HTTP asks before connecting
    /// unencrypted, and accepting lands on Login.
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

    /// Focusing the address field scrolls the whole manual-entry block —
    /// the HTTPS toggle included — above the keyboard and the pinned Connect
    /// bar. The scan section above it pushes the toggle below the keyboard's
    /// top edge on a phone otherwise.
    ///
    /// Needs the software keyboard; a simulator with "Connect Hardware
    /// Keyboard" on never shows one, so the test skips rather than passing on
    /// nothing.
    func testFocusingTheAddressFieldKeepsTheHTTPSToggleAboveTheKeyboard() throws {
        launch(signedIn: false)

        let serverSetup = ServerSetupScreen(app: app)
        // Scan results make the section above the field taller, which is
        // what takes the toggle below the keyboard on a phone.
        serverSetup.scanForStubServer()
        serverSetup.addressField.tap()

        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            throw XCTSkip("No software keyboard on this simulator.")
        }

        let toggle = serverSetup.httpsToggle
        let connect = serverSetup.connectButton
        let clear = NSPredicate { _, _ in
            toggle.exists && toggle.frame.maxY <= min(keyboard.frame.minY, connect.frame.minY)
        }
        let settled = XCTNSPredicateExpectation(predicate: clear, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 5), .completed,
            "The HTTPS toggle (maxY \(toggle.frame.maxY)) should sit above the keyboard (minY \(keyboard.frame.minY)) and the Connect bar (minY \(connect.frame.minY))."
        )
        XCTAssertTrue(toggle.isHittable)
    }

    /// "Use a Different Server" from Login discards the server configuration
    /// and returns to server setup — the backtrack `AppState.changeServer()`
    /// drives, reachable without ever having signed in.
    func testChangingServerFromLoginReturnsToServerSetup() {
        launch(signedIn: false)

        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.changeServerButton.tap()

        ServerSetupScreen(app: app).awaitLoaded()
    }
}
