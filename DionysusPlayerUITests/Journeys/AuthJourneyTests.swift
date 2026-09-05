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
