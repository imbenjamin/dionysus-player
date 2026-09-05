import XCTest

/// Deeper Search coverage than `SmokeJourneyTests.testSearchingFindsAKnownTitle`
/// — the empty state and history surviving a relaunch.
///
/// Two things this deliberately doesn't cover, both real findings rather
/// than gaps in this suite:
///
/// - **Swiping a history row away.** `SearchResultRow` wraps the whole row
///   in a `Button`, and measured live, a synthesized `.swipeLeft()` on it
///   can register as a tap instead of a swipe — reopening the row's own
///   detail page rather than revealing the delete action. Same class of
///   gesture-synthesis unreliability as this suite's documented
///   scroll-gesture avoidance; stays a manual/device check.
/// - **The Search tab's own re-tap-to-reset** (`MainTabView
///   .searchResetToken`/`dismissSearch()`). Measured live on iPad: once the
///   search field has ever been engaged, the floating tab bar disappears
///   from the accessibility tree entirely — not merely occluded by the
///   keyboard (it sits at the top of the screen; the keyboard, the bottom),
///   and not something popping back to the results list undoes. Whether a
///   real user can reach that tab bar at all in this state — the one
///   documented way back to the landing page — needs its own investigation,
///   not a workaround buried in this test.
final class SearchJourneyTests: UITestCase {
    func testSearchingForAnUnknownTermShowsTheEmptyState() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).search.tap()

        SearchScreen(app: app).search(for: "zzz-no-such-title")
        SearchScreen(app: app).emptyState.awaitExistence("the search empty state")
    }

    /// Selecting a result records it to history (`SearchViewModel
    /// .recordSelection`), which is keyed by user id in `UserDefaults` — so
    /// unlike almost every other journey here, the second launch has to
    /// skip `-UITestResetState` (see `UITestCase.launch(resetsState:)`) to
    /// prove the entry actually survived the relaunch rather than just
    /// still being in memory from the first.
    func testHistoryPersistsAcrossARelaunch() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).search.tap()

        let search = SearchScreen(app: app)
        search.search(for: "Quiet")
        let firstResult = search.result(UITestFixtureIdentity.primaryMovieID)
        firstResult.awaitExistence("the matching result tile")
        firstResult.tap()

        AssetDetailScreen(app: app).awaitLoaded()
        app.terminate()

        launch(resetsState: false)
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).search.tap()

        // iOS can restore the Search tab's own pushed detail page from the
        // previous launch's scene state (measured live) even though
        // `-UITestResetState` was skipped only for `UserDefaults`/the
        // Keychain — that restoration is the OS's own, separate from
        // anything this harness controls. Pop back to Search's root before
        // asserting on history, rather than assuming the relaunch landed
        // there directly.
        while app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
        }

        SearchScreen(app: app).result(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("the persisted history row")
    }
}
