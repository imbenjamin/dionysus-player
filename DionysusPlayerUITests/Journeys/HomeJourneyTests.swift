import XCTest

/// Deeper Home coverage than `SmokeJourneyTests` — the hero carousel and the
/// rail "See All" push.
///
/// Not covered here, deliberately: the VoiceOver-only refresh button, which
/// only mounts under `accessibilityVoiceOverEnabled` — something XCUITest
/// does not turn on. That stays an exploratory/device check.
final class HomeJourneyTests: UITestCase {
    func testHeroCarouselIsVisible() {
        launch()
        HomeScreen(app: app).awaitLoaded()

        HomeScreen(app: app).heroCarousel.awaitExistence("Home's hero carousel")
    }

    /// The "Recently Added Movies" rail's "See All" pushes the Movies
    /// library's collection grid, preset to newest-first — a different path
    /// to the same grid `SmokeJourneyTests.testOpeningAnItemFromACollectionGrid`
    /// reaches through the library card instead.
    func testSeeAllPushesTheMoviesCollectionGrid() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()

        let seeAll = home.seeAllRecentMoviesButton
        seeAll.awaitExistence("the Recently Added Movies rail's See All link")
        seeAll.tap()

        CollectionScreen(app: app).awaitLoaded(UITestFixtureIdentity.primaryMovieID)
    }

    /// A hard refresh must leave every rail scrolled back to its first item,
    /// so a refreshed Home reads from item #1 like a fresh launch
    /// (`HomeViewModel.railResetToken`). Asserted on the library rail, the
    /// one rail with a proven-reliable horizontal swipe in this suite (see
    /// `HomeScreen.openLibrary`): scroll the first card off the leading edge,
    /// pull to refresh, and it must be back.
    ///
    /// The `-UITestResetState` fixtures are identical across the refresh, so
    /// only the scroll offset can change here — which is exactly the claim.
    func testHardRefreshScrollsRailsBackToTheirFirstItem() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()

        let firstLibrary = home.card(UITestFixtureIdentity.moviesLibraryID)
        firstLibrary.awaitExistence("the Movies library card")
        let restingMinX = firstLibrary.frame.minX

        app.descendants(matching: .any)[A11yID.Home.libraryRail].swipeLeft()
        XCTAssertLessThan(
            home.card(UITestFixtureIdentity.moviesLibraryID).frame.minX, restingMinX,
            "The swipe must actually move the library rail, or the rest of this test proves nothing"
        )

        home.pullToRefresh()

        // Polled rather than asserted once: the reset lands only after the
        // refresh's fetches complete, which is a few frames after the pull
        // gesture returns.
        let deadline = Date().addingTimeInterval(UITestCase.defaultTimeout)
        var minX = home.card(UITestFixtureIdentity.moviesLibraryID).frame.minX
        while minX < restingMinX, Date() < deadline {
            minX = home.card(UITestFixtureIdentity.moviesLibraryID).frame.minX
        }
        XCTAssertEqual(
            minX, restingMinX, accuracy: 1,
            "A hard refresh must scroll the library rail back to its first card"
        )
    }
}
