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
