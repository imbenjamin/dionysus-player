import XCTest

/// The subset that gates every PR (`TestPlans/UITests-Smoke.xctestplan`).
///
/// Deliberately small. These are the paths where a break stops the app being
/// usable at all — sign in, see content, open something, play it, search —
/// and the point of running them on every PR is fast feedback, not coverage.
/// The broader per-feature journeys belong in the full plan.
final class SmokeJourneyTests: UITestCase {
    /// First run: no server, no credentials. Types a real address, signs in,
    /// and lands on Home with content.
    ///
    /// The one test that exercises `AppState`'s whole `.serverSetup` →
    /// `.login` → `.main` machine rather than being seeded past it.
    func testFirstRunSetupAndSignIn() {
        launch(signedIn: false)

        ServerSetupScreen(app: app).connect(to: UITestFixtureIdentity.serverAddress)

        LoginScreen(app: app).signIn(
            username: UITestFixtureIdentity.username,
            password: UITestFixtureIdentity.password
        )

        HomeScreen(app: app).awaitLoaded()
    }

    /// A seeded session resolves the splash straight to Home. Covers
    /// `AppState.start()`'s silent re-authentication path, which every other
    /// test depends on and none of them would otherwise assert.
    func testSeededSessionOpensOnHome() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        XCTAssertTrue(TabBar(app: app).home.exists, "The main tab bar should be present once signed in.")
    }

    /// Home → detail push. Guards the `LazyHStack`/`NavigationLink` layout
    /// hang that has been fixed twice in this codebase: if it regresses, the
    /// tap never resolves and this times out rather than failing an
    /// assertion about content.
    func testOpeningAnItemFromHome() {
        launch()

        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        AssetDetailScreen(app: app).awaitLoaded()
    }

    /// Detail → player → back. The player runs on the fake engine, so this
    /// covers presentation, the controls overlay and dismissal — not decode,
    /// which stays a device-only check.
    func testPlayingAndClosingAnItem() {
        launch()

        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.play()

        let player = PlayerScreen(app: app)
        player.awaitControls()
        XCTAssertTrue(player.playPauseButton.exists, "The transport controls should be reachable.")
        player.close()

        player.closeButton.awaitDisappearance("the player")
        detail.awaitLoaded()
    }

    /// Home → library card → Collection grid → poster tile → detail.
    ///
    /// Deliberately separate from `testOpeningAnItemFromHome`, which opens
    /// the *same item* but reaches it through the hero carousel. Both
    /// surfaces carry `A11yID.Media.card(_:)`, and `.firstMatch` on Home
    /// resolves to the hero card — so without this test, `PosterCard` (the
    /// tile used by every rail and every grid) is never actually tapped.
    /// Found by breaking `PosterCard`'s destination on purpose and watching
    /// the suite stay green.
    ///
    /// Also covers the library card → collection push, which is the
    /// `LazyHStack`/`NavigationLink` shape that has hung layout twice.
    func testOpeningAnItemFromACollectionGrid() {
        launch()

        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)
        collection.card(UITestFixtureIdentity.partWatchedMovieID).tap()

        AssetDetailScreen(app: app).awaitLoaded()
    }

    /// Search returns results for a fixture title.
    func testSearchingFindsAKnownTitle() {
        launch()
        HomeScreen(app: app).awaitLoaded()

        TabBar(app: app).search.tap()

        let search = SearchScreen(app: app)
        search.search(for: "Quiet")
        search.result(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("the matching result tile")
    }
}
