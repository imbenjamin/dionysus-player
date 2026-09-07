import XCTest

/// The error/offline scenarios `UITestStubURLProtocol` supports — everything
/// other than `.standard`/`.emptyLibrary`, both already covered elsewhere
/// (the smoke plan's happy path, and Collection's own filter tests touch
/// `.emptyLibrary` indirectly through empty facets).
final class OfflineErrorJourneyTests: UITestCase {
    /// `.serverError` fails every browse endpoint with 500 (auth itself is
    /// exempt — see `UITestStubURLProtocol.isInfrastructurePath` — so a
    /// seeded session still reaches `.main` before Home's own fetch fails).
    func testServerErrorScenarioShowsAnErrorState() {
        launch(scenario: "serverError")

        StateViewsScreen(app: app).errorState.awaitExistence("Home's error state")
    }

    /// `.unauthorized` fails each path with 401 exactly once, then succeeds
    /// — `JellyfinAPIClient.sendRaw`'s silent re-authentication should
    /// recover transparently, with Home ending up fully loaded rather than
    /// stuck on an error or bounced to Login. A longer timeout than the
    /// suite default: `reauthBackoffSchedule` adds real, if invisible,
    /// latency to the first retry (see `TESTING.md`'s flake-source table).
    func testUnauthorizedScenarioRecoversSilentlyAndReachesHome() {
        launch(scenario: "unauthorized")

        HomeScreen(app: app).awaitLoaded(timeout: 25)
    }

    /// `.offline` fails every request as unreachable, driving
    /// `ConnectivityMonitor.isOffline` — Home should show the offline
    /// state, and the Downloads tab (reading local storage only, unrelated
    /// to connectivity) should still be reachable alongside it.
    func testOfflineScenarioShowsOfflineStateWithDownloadsStillReachable() {
        launch(scenario: "offline")

        StateViewsScreen(app: app).offlineState.awaitExistence("Home's offline state")

        TabBar(app: app).downloads.tap()
        DownloadsScreen(app: app).emptyState.awaitExistence("the Downloads tab, still reachable while offline")
    }
}

/// The shared loading/error/offline placeholders (`Shared/Components/StateViews.swift`),
/// addressed generically rather than per-screen — several screens render
/// the same `A11yID.State` identifiers for the same conditions.
private struct StateViewsScreen: Screen {
    let app: XCUIApplication

    var errorState: XCUIElement { app.descendants(matching: .any)[A11yID.State.error] }
    var offlineState: XCUIElement { app.descendants(matching: .any)[A11yID.State.offline] }
}
