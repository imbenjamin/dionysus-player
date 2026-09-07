import XCTest

/// Deeper Home coverage than `SmokeJourneyTests` — the hero carousel and the
/// rail "See All" push.
///
/// Not covered here, deliberately: pull-to-refresh and the VoiceOver-only
/// refresh button. `.refreshable`'s pull gesture is a `ScrollView` drag,
/// which this codebase has already found unreliable to automate (see
/// `simulator-ui-verification-scope` in the project's own notes); the
/// refresh *button* only mounts under `accessibilityVoiceOverEnabled`, which
/// XCUITest does not turn on. Both stay exploratory/device checks.
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
}
