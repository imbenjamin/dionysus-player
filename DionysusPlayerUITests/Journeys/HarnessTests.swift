import XCTest

/// Tests of the harness itself rather than of a user journey.
///
/// Worth having: every other test in this bundle is only meaningful if the
/// stub is actually serving and the state reset actually resets. When those
/// break, they break silently — a test that "passes" against a real network
/// or against a previous run's leftovers is worse than one that fails.
final class HarnessTests: UITestCase {
    /// `.emptyLibrary` empties every collection endpoint, so Home has no
    /// content to show. Proves the scenario switch reaches the app and that
    /// the stub — not the network — is answering: no real server would
    /// return an empty catalogue and a valid sign-in at the same time.
    func testEmptyLibraryScenarioIsServed() {
        launch(scenario: "emptyLibrary")

        // No tile for any fixture item, but the app is signed in and past
        // the splash, which is what distinguishes "stub served nothing" from
        // "nothing loaded at all".
        TabBar(app: app).home.awaitExistence("the main tab bar")
        XCTAssertFalse(
            HomeScreen(app: app).card(UITestFixtureIdentity.primaryMovieID).exists,
            "The empty-library scenario should serve no items."
        )
    }

    /// A signed-in run followed by a fresh launch without `-UITestSeedSession`
    /// must land back at server setup.
    ///
    /// This is the assertion that protects every other test's isolation. The
    /// credentials live in the Keychain, which outlives the app container —
    /// so if `-UITestResetState` ever stopped clearing it, the first launch
    /// of every later test would silently start signed in, and a test meaning
    /// to cover first-run would quietly stop covering anything.
    func testStateResetClearsTheKeychainBetweenLaunches() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        app.terminate()

        launch(signedIn: false)
        ServerSetupScreen(app: app).awaitLoaded()
    }

    /// `.offline` fails every request as unreachable, which should surface
    /// the shared offline state rather than an error or an empty screen.
    func testOfflineScenarioShowsTheOfflineState() {
        launch(scenario: "offline")

        app.descendants(matching: .any)[A11yID.State.offline]
            .awaitExistence("the offline state")
    }
}
