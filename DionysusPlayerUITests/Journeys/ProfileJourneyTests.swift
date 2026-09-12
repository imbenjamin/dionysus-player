import XCTest

/// Profile coverage: the two destructive account actions reachable through
/// the account card (`ProfileScreen`'s doc comment explains why this
/// stays scoped to just those — the rest of Profile forks by device in a
/// way this suite doesn't yet absorb).
final class ProfileJourneyTests: UITestCase {
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
