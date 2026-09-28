import XCTest

/// Downloads tab coverage: the empty state, enqueuing and completing a
/// download from the detail page, and bulk delete.
///
/// `UITestStubURLProtocol` answers `/Videos/`/`/Subtitles/` with a small
/// fixed byte payload (see that type's doc comment) — real bytes
/// `DownloadManager` really does write to disk via a real
/// `URLSessionDownloadTask`, just tiny and instant rather than the size/
/// duration a real movie download would take. That's what makes asserting
/// on a *completed* download practical here at all.
final class DownloadsJourneyTests: UITestCase {
    func testDownloadsTabShowsEmptyStateWithNothingDownloaded() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).downloads.tap()

        DownloadsScreen(app: app).emptyState.awaitExistence("the Downloads empty state")
    }

    /// Detail page → Download → the audio-track prompt (the fixture movie
    /// carries two audio tracks, see `UITestFixtureLibrary.mediaSource(for:)`)
    /// → the button settles on its "Downloaded" state. No subtitle warning
    /// dialog appears in between: the fixture's default subtitle track
    /// codec is `subrip`, not one of `JellyfinAPIClient
    /// .isImageBasedSubtitleCodec`'s formats.
    func testDownloadingAnItemMarksItDownloadedOnTheDetailPage() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.downloadButton.tap()

        let audioChoice = app.buttons["ENG EAC3"]
        audioChoice.awaitExistence("the audio-track prompt's default track option")
        audioChoice.tap()

        detail.awaitDownloadCompletion()

        TabBar(app: app).downloads.tap()
        DownloadsScreen(app: app).list.awaitExistence("the Downloads list with the completed download")
    }

    /// The Downloads tab opened while a download is still in flight, then left
    /// on screen while it finishes. The row must leave its "Preparing
    /// download…" state on its own: it once sat there indefinitely, because
    /// the list snapshots each row's status and only re-read the store on
    /// appear (see `DownloadsViewModel.followStoreChanges()`). The other
    /// journeys here finish the download before opening the tab, so they
    /// could never see it.
    ///
    /// Asserts on the row's label — English copy — because the status has no
    /// element of its own: the list row and the grid tile each collapse to one.
    func testADownloadFinishingWhileTheTabIsOpenUpdatesItsRow() {
        launch(scenario: "slowVideoDownload")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.downloadButton.tap()
        app.buttons["ENG EAC3"].awaitExistence("the audio-track prompt's default track option").tap()

        TabBar(app: app).downloads.tap()
        let row = DownloadsScreen(app: app).standaloneRow(itemID: UITestFixtureIdentity.primaryMovieID)
        row.awaitExistence("the in-flight download's row")
        XCTAssertTrue(
            row.label.contains("Preparing download"),
            "Expected the row to still be in flight when the tab opened, but its label was \"\(row.label)\"; the stub's hold is too short to test anything."
        )

        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (label CONTAINS[c] %@)", "Preparing download"),
            object: row
        )
        XCTAssertEqual(
            // The stub's 10s hold (`slowVideoDownloadDelay`, app-side) plus the
            // usual budget for the rest.
            XCTWaiter().wait(for: [finished], timeout: 10 + UITestCase.defaultTimeout),
            .completed,
            "The row never left \"Preparing download…\" after its download finished; its label is still \"\(row.label)\"."
        )
    }

    /// Downloads an item, then removes it again through selection mode —
    /// Select, Select All, the trash button, and the confirmation dialog —
    /// back down to the empty state.
    func testDeletingAllDownloadsReturnsToTheEmptyState() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.downloadButton.tap()
        app.buttons["ENG EAC3"].awaitExistence("the audio-track prompt's default track option").tap()
        detail.awaitDownloadCompletion()

        TabBar(app: app).downloads.tap()
        let downloads = DownloadsScreen(app: app)
        downloads.list.awaitExistence("the Downloads list with the completed download")

        downloads.deleteAllRows()

        downloads.emptyState.awaitExistence("the Downloads empty state after deleting everything")
    }

    /// Select, then Cancel: selection mode ends with nothing deleted, and the
    /// trash (which only ever deletes) goes away with it. Pins the shared
    /// `DownloadsSelectionToolbar`'s round trip, which the delete journey above
    /// never takes.
    func testCancellingSelectionKeepsTheDownloads() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.downloadButton.tap()
        app.buttons["ENG EAC3"].awaitExistence("the audio-track prompt's default track option").tap()
        detail.awaitDownloadCompletion()

        TabBar(app: app).downloads.tap()
        let downloads = DownloadsScreen(app: app)
        downloads.list.awaitExistence("the Downloads list with the completed download")

        downloads.selectButton.awaitExistence("the Select button").tap()
        downloads.deleteSelectedButton.awaitExistence("the trash button in selection mode")
        XCTAssertFalse(downloads.deleteSelectedButton.isEnabled, "trash with nothing selected")

        downloads.cancelSelectionButton.tap()
        downloads.selectButton.awaitExistence("the Select button again after cancelling")
        XCTAssertFalse(downloads.deleteSelectedButton.exists, "trash outside selection mode")
        XCTAssertTrue(downloads.list.exists, "the download, still there")
    }
}

