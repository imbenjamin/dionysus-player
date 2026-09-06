import XCTest

/// Downloads tab coverage: the empty state, enqueuing and completing a
/// download from the detail page, and bulk delete.
///
/// `UITestStubURLProtocol` answers `/Videos/`/`/Subtitles/` with a small
/// fixed byte payload (see that type's own doc comment) — real bytes
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
}
