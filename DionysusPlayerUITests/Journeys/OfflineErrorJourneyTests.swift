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

    /// In book pose on the iPhone Duo, Home's offline state and the empty
    /// Downloads tab sit on the trailing page, as Search's states do
    /// (`.centredClearOfTheFold()`); they spanned the fold, full width.
    func testOfflineAndEmptyDownloadsStatesSitOnTheTrailingPageInBookPose() throws {
        launch(scenario: "offline")
        guard duoPose == "book", let fold = duoFoldBand(), fold.height > fold.width else {
            throw XCTSkip("Only the iPhone Duo in book pose moves these states off the fold.")
        }

        StateViewsScreen(app: app).offlineState.firstMatch.awaitExistence("Home's offline state")
        assertOnTheTrailingPage(A11yID.State.offline, of: fold, "Home's offline state")

        TabBar(app: app).downloads.tap()
        DownloadsScreen(app: app).emptyState.firstMatch.awaitExistence("the Downloads empty state")
        assertOnTheTrailingPage(A11yID.Downloads.emptyState, of: fold, "The Downloads empty state")
    }

    /// Every element carrying `identifier` (a state's identifier reaches its
    /// text and button too) starts past the fold. Waits a moment: the state
    /// moves once the fold is read, a pass after it appears.
    private func assertOnTheTrailingPage(_ identifier: String, of fold: CGRect, _ name: String) {
        let elements = app.descendants(matching: .any).matching(identifier: identifier)
        let clear = NSPredicate { _, _ in
            let all = elements.allElementsBoundByIndex
            return !all.isEmpty && all.allSatisfy { $0.frame.minX >= fold.maxX }
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: clear, object: nil)], timeout: Self.defaultTimeout)
        XCTAssertEqual(
            result, .completed,
            "\(name) should start past the fold \(fold): \(elements.allElementsBoundByIndex.map(\.frame))."
        )
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
