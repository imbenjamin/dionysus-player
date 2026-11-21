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

    // MARK: - Offline (TQ-05)

    /// The point of a download: with no server, the movie's downloaded page
    /// opens from the Downloads tab and plays.
    func testADownloadedMovieOpensAndPlaysOffline() {
        launch()
        download(UITestFixtureIdentity.primaryMovieID)

        let downloads = relaunchOffline()
        downloads.standaloneRow(itemID: UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("the movie's row, offline").tap()
        let play = app.buttons[A11yID.Downloads.playButton]
        play.awaitExistence("the downloaded page's Play").tap()

        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.close()
        player.closeButton.awaitDisappearance("the player")
        play.awaitExistence("back on the downloaded page")
    }

    /// A lone downloaded episode is listed on its own (not under its show),
    /// and its downloaded page opens and plays offline. Two or more group
    /// under their show: the journeys below.
    func testADownloadedEpisodeOpensAndPlaysOffline() {
        let episodeID = UITestFixtureIdentity.episodeID(season: 1, episode: 1)
        launch()
        download(episodeID)

        relaunchOffline().standaloneRow(itemID: episodeID)
            .awaitExistence("the episode's row, offline").tap()
        app.buttons[A11yID.Downloads.playButton].awaitExistence("the downloaded episode's Play").tap()

        PlayerScreen(app: app).awaitControls()
    }

    /// One season downloaded: the Downloads tab lists the show, whose page
    /// lists the season's episodes flat, and one of them plays offline.
    func testADownloadedSeasonOpensFromItsShowAndPlaysOffline() {
        launch()
        downloadSeasons(["season-1"])

        let downloads = relaunchOffline()
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID)
            .awaitExistence("the show's row, offline").tap()

        for episode in 1...3 {
            downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: episode))
                .awaitExistence("Season 1, Episode \(episode) on the show's page")
        }
        XCTAssertFalse(
            downloads.seasonRow(seasonID: "season-1").exists,
            "One season downloaded: the show's page lists episodes, not seasons."
        )

        downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: 2)).tap()
        let play = app.buttons[A11yID.Downloads.playButton]
        play.awaitExistence("the downloaded episode's Play").tap()

        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.close()
        player.closeButton.awaitDisappearance("the player")
        play.awaitExistence("back on the downloaded episode's page")
    }

    /// Two seasons downloaded: the show's page lists them as seasons, a
    /// season's page lists only its own episodes, and one plays offline.
    func testTwoDownloadedSeasonsGroupOnTheShowPageAndPlayOffline() {
        launch()
        downloadSeasons(["season-1", "season-2"])

        let downloads = relaunchOffline()
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID)
            .awaitExistence("the show's row, offline").tap()

        downloads.seasonRow(seasonID: "season-1").awaitExistence("Season 1 on the show's page")
        downloads.seasonRow(seasonID: "season-2").awaitExistence("Season 2 on the show's page").tap()

        for episode in 1...3 {
            downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 2, episode: episode))
                .awaitExistence("Season 2, Episode \(episode) on the season's page")
        }
        XCTAssertFalse(
            downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "Season 2's page lists Season 1's episodes."
        )

        downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 2, episode: 3)).tap()
        app.buttons[A11yID.Downloads.playButton].awaitExistence("the downloaded episode's Play").tap()
        PlayerScreen(app: app).awaitControls()
    }

    // MARK: - Up Next offline, Delete & Play Next (#274)

    /// Downloads under `.earlyCredits` keep its credits at 0:05, so offline the
    /// Up Next card shows about 5 s into S1:E1 and counts down 10 s. Opens
    /// S1:E1's downloaded page from the show and plays it.
    private func playDownloadedEpisodeOneOffline(
        download: () -> Void, file: StaticString = #filePath, line: UInt = #line
    ) -> (DownloadsScreen, PlayerScreen) {
        launch(scenario: "earlyCredits")
        download()
        let downloads = relaunchOffline()
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID)
            .awaitExistence("the show's row, offline", file: file, line: line).tap()
        downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: 1))
            .awaitExistence("S1:E1 on the show's page", file: file, line: line).tap()
        app.buttons[A11yID.Downloads.playButton].awaitExistence("S1:E1's Play", file: file, line: line).tap()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return (downloads, player)
    }

    private var episodeOne: String { UITestFixtureIdentity.episodeID(season: 1, episode: 1) }
    private var episodeTwo: String { UITestFixtureIdentity.episodeID(season: 1, episode: 2) }

    /// Closes the player, which has moved on to S1:E2, and checks the page
    /// followed it there; then goes back to the show's page.
    private func closeAndExpectEpisodeTwosPage(_ player: PlayerScreen) {
        player.close()
        player.closeButton.awaitDisappearance("the player")
        app.buttons[A11yID.Downloads.detailDeleteButton(episodeTwo)]
            .awaitExistence("S1:E2's page: the page followed playback")
        app.navigationBackButton.tap()
    }

    func test_offlineNextUp_deleteAndPlayNext_playsTheNext_landsOnIt_andDeletesTheFinished() {
        let (downloads, player) = playDownloadedEpisodeOneOffline { downloadSeasons(["season-1"]) }
        player.nextUpCard.awaitExistence("the Up Next card, in the credits", timeout: 30)
        XCTAssertTrue(player.nextUpDeleteAndPlayNext.exists, "A download's card offers Delete & Play Next")
        XCTAssertFalse(player.nextUpPlayNow.exists, "Delete & Play Next takes Play Now's place")
        XCTAssertTrue(player.nextUpCancel.exists)

        player.nextUpDeleteAndPlayNext.tap()
        player.awaitControls()
        closeAndExpectEpisodeTwosPage(player)

        downloads.episodeRow(itemID: episodeTwo).awaitExistence("S1:E2 still downloaded")
        downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: 3))
            .awaitExistence("S1:E3 still downloaded")
        XCTAssertFalse(downloads.episodeRow(itemID: episodeOne).exists, "S1:E1's download was deleted")
    }

    func test_offlineNextUp_countdown_playsTheNext_andDeletesNothing() {
        let (downloads, player) = playDownloadedEpisodeOneOffline { downloadSeasons(["season-1"]) }
        player.nextUpCard.awaitExistence("the Up Next card, in the credits", timeout: 30)
        // The countdown runs out by itself: no tap.
        player.nextUpCard.awaitDisappearance("the card, once the countdown advanced", timeout: 30)
        player.awaitControls()
        closeAndExpectEpisodeTwosPage(player)

        downloads.episodeRow(itemID: episodeOne).awaitExistence("S1:E1 kept: the countdown never deletes")
    }

    func test_offlineNextUp_cancel_deletesNothing() {
        let (downloads, player) = playDownloadedEpisodeOneOffline { downloadSeasons(["season-1"]) }
        player.nextUpCard.awaitExistence("the Up Next card, in the credits", timeout: 30)
        player.nextUpCancel.tap()
        player.nextUpCard.awaitDisappearance("the card, cancelled")
        player.close()
        player.closeButton.awaitDisappearance("the player")
        app.buttons[A11yID.Downloads.detailDeleteButton(episodeOne)]
            .awaitExistence("still S1:E1's page")
        app.navigationBackButton.tap()

        downloads.episodeRow(itemID: episodeOne).awaitExistence("S1:E1 kept")
    }

    /// S1:E2 isn't downloaded, so S1:E1 cues nothing: no skipping to S1:E3.
    /// The gap is made as a viewer would: the season downloaded, then S1:E2's
    /// download deleted from its page (a row's download button sat out of
    /// reach on a tabletop Duo).
    func test_offlineNextUp_gap_showsNoCard() {
        launch(scenario: "earlyCredits")
        downloadSeasons(["season-1"])
        let downloads = relaunchOffline()
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID).awaitExistence("the show's row, offline").tap()
        downloads.episodeRow(itemID: episodeTwo).awaitExistence("S1:E2 on the show's page").tap()
        app.buttons[A11yID.Downloads.detailDeleteButton(episodeTwo)].awaitExistence("S1:E2's Delete Download").tap()
        let confirm = app.buttons.matching(identifier: A11yID.Downloads.detailDeleteConfirmButton).firstMatch
        confirm.awaitExistence("the delete confirmation").tap()
        downloads.episodeRow(itemID: episodeTwo).awaitDisappearance("S1:E2's row, deleted")

        downloads.episodeRow(itemID: episodeOne).awaitExistence("S1:E1 on the show's page").tap()
        app.buttons[A11yID.Downloads.playButton].awaitExistence("S1:E1's Play").tap()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        // Past the credits' start and where the card would have shown.
        RunLoop.current.run(until: Date().addingTimeInterval(12))
        XCTAssertFalse(player.nextUpCard.exists, "A gap gets no Up Next")
    }

    // MARK: - Advanced options (TQ-11)

    /// Holding Download opens the per-item options instead of downloading:
    /// Cancel starts nothing, a lower Quality lowers the estimate, and the
    /// sheet's Download goes on through the usual audio prompt to a
    /// finished download.
    func testHoldingDownloadOffersPerItemQuality() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()

        let sheet = detail.openAdvancedDownloadOptions()
        sheet.cancelButton.tap()
        sheet.downloadButton.awaitDisappearance("the advanced options sheet, cancelled")
        XCTAssertFalse(app.buttons["ENG EAC3"].exists, "Cancel shouldn't start a download")
        XCTAssertFalse(detail.downloadButton.label.localizedCaseInsensitiveContains("Downloaded"))

        detail.openAdvancedDownloadOptions()
        let estimate = sheet.estimatedSize.awaitExistence("the Estimated Size")
        let normalEstimate = estimate.label
        sheet.selectQuality("dataSaver")
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", normalEstimate), object: estimate
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [changed], timeout: 5), .completed,
            "Data Saver should change the estimate from \(normalEstimate)"
        )

        sheet.downloadButton.tap()
        let audioChoice = app.buttons["ENG EAC3"]
        audioChoice.awaitExistence("the audio-track prompt, after the sheet's Download")
        audioChoice.tap()
        detail.awaitDownloadCompletion()
    }

    // MARK: - Versions (#289)

    /// Under `multipleVersions`, movie 1 ("The Quiet Ascent") is a 4K HDR10
    /// and a 1080p file, each with the fixture's two audio tracks.
    private let quietAscent = UITestFixtureIdentity.primaryMovieID

    private func openQuietAscent() -> AssetDetailScreen {
        launch(scenario: "multipleVersions")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(quietAscent)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    /// Opens the movie's downloaded page from the Downloads tab and checks
    /// its Details tab's Version row reads `label`.
    private func assertDownloadedVersion(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        TabBar(app: app).downloads.tap()
        let downloads = DownloadsScreen(app: app)
        downloads.standaloneRow(itemID: quietAscent).awaitExistence("the download's row", file: file, line: line).tap()
        assertOpenDownloadReadsVersion(label, file: file, line: line)
    }

    /// Checks the downloaded page on screen: its Details tab's Version row
    /// reads `label`.
    private func assertOpenDownloadReadsVersion(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let downloads = DownloadsScreen(app: app)
        let details = downloads.detailTab("details")
        details.awaitExistence("the downloaded page's Details tab", file: file, line: line)
        // Swiped on the page's Play, never `app`, which on the Duo starts on
        // the fold.
        let play = app.buttons[A11yID.Downloads.playButton]
        for _ in 0..<4 where !details.isHittable && play.isHittable { play.swipeUp() }
        details.tap()
        downloads.detailsVersionValue.awaitExistence("the Details tab's Version row", file: file, line: line)
        XCTAssertEqual(downloads.detailsVersionValue.label, label, file: file, line: line)
    }

    /// Download asks which version first, then which audio track of it; the
    /// download records the version, and its Details says which.
    func test_download_multiVersionMovie_asksVersionThenAudio_andShowsVersionOnTheDownload() {
        let detail = openQuietAscent()
        detail.downloadButton.tap()

        detail.versionOption("\(quietAscent)-4k").awaitExistence("the version question's 4K HDR10")
        detail.versionOption("\(quietAscent)-1080p").tap()
        let audioChoice = app.buttons["ENG EAC3"]
        audioChoice.awaitExistence("the audio-track prompt, after the version")
        audioChoice.tap()
        detail.awaitDownloadCompletion()

        assertDownloadedVersion("1080p")
    }

    /// Dismissing the version question starts nothing: no audio prompt, and
    /// the button is back to its idle Download.
    func test_download_cancelVersion_startsNothing() {
        let detail = openQuietAscent()
        detail.downloadButton.tap()
        let option = detail.versionOption("\(quietAscent)-1080p")
        option.awaitExistence("the version question")
        detail.dismissVersionQuestion()
        option.awaitDisappearance("the version question")

        // Long enough for the audio prompt to have come had the dismissal
        // carried on.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.buttons["ENG EAC3"].exists, "No audio prompt after a cancelled version question")
        XCTAssertTrue(detail.downloadButton.isEnabled, "The button is idle again")
        XCTAssertFalse(detail.downloadButton.label.localizedCaseInsensitiveContains("Downloaded"))
        XCTAssertFalse(detail.downloadButton.label.localizedCaseInsensitiveContains("Preparing"))
    }

    /// The long-press sheet picks the version itself (D9): its Download goes
    /// straight to the audio prompt, with no version question in between,
    /// and the download is the version the sheet chose.
    func test_advancedOptions_hasVersionPicker_andSkipsTheDialog() {
        let detail = openQuietAscent()
        let sheet = detail.openAdvancedDownloadOptions()
        sheet.selectVersion("\(quietAscent)-1080p")

        sheet.downloadButton.tap()
        let audioChoice = app.buttons["ENG EAC3"]
        let deadline = Date().addingTimeInterval(UITestCase.defaultTimeout)
        while !audioChoice.exists, Date() < deadline {
            XCTAssertFalse(detail.anyVersionOption.exists, "No version question after the sheet")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        audioChoice.awaitExistence("the audio-track prompt, after the sheet's Download")
        audioChoice.tap()
        detail.awaitDownloadCompletion()

        assertDownloadedVersion("1080p")
    }

    // MARK: - Season versions (#289)

    /// Under `multipleVersions`, the show's Season 1 episodes are each a 4K
    /// HDR10 and a 1080p file; Season 2 is mixed (S2:E1 the same pair, S2:E2
    /// Original and Extended Edition, S2:E3 one file).
    private func openShowWithVersions() -> AssetDetailScreen {
        launch(scenario: "multipleVersions")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)
        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    /// Season 1's episodes all have the same versions: one question, and its
    /// answer is every episode's download.
    func test_seasonDownload_matchingVersions_asksOnce() {
        let detail = openShowWithVersions()
        detail.seasonDownloadButton.awaitExistence("the season's download button").tap()

        let hd = detail.bulkVersionOption(1)
        hd.awaitExistence("the season's version question")
        XCTAssertEqual(hd.label, "1080p", "The question lists the versions in the server's order")
        hd.tap()
        XCTAssertFalse(
            detail.bulkRowPicker(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "Matching versions ask once, never per episode"
        )
        detail.awaitSeasonDownloaded()

        TabBar(app: app).downloads.tap()
        let downloads = DownloadsScreen(app: app)
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID).awaitExistence("the show's row").tap()
        for episode in 1...3 {
            downloads.episodeRow(itemID: UITestFixtureIdentity.episodeID(season: 1, episode: episode))
                .awaitExistence("Season 1, Episode \(episode) on the show's page").tap()
            assertOpenDownloadReadsVersion("1080p")
            app.navigationBackButton.tap()
        }
    }

    /// Season 2's versions differ: a sheet lists only the episodes with a
    /// choice, and each downloads the version picked for it.
    func test_seasonDownload_differingVersions_asksPerEpisode() {
        let detail = openShowWithVersions()
        detail.selectSeason("season-2")
        detail.seasonDownloadButton.awaitExistence("the season's download button").tap()

        let e1 = UITestFixtureIdentity.episodeID(season: 2, episode: 1)
        let e2 = UITestFixtureIdentity.episodeID(season: 2, episode: 2)
        let e3 = UITestFixtureIdentity.episodeID(season: 2, episode: 3)
        detail.bulkRowPicker(e1).awaitExistence("S2:E1's row in the sheet")
        detail.bulkRowPicker(e2).awaitExistence("S2:E2's row in the sheet")
        XCTAssertFalse(detail.bulkRowPicker(e3).exists, "A single-version episode has no row")
        XCTAssertFalse(detail.bulkVersionOption(0).exists, "Differing versions never ask once")

        detail.selectBulkVersion(episodeID: e2, versionID: "\(e2)-extended")
        detail.bulkDownloadButton.tap()
        detail.awaitSeasonDownloaded()

        TabBar(app: app).downloads.tap()
        let downloads = DownloadsScreen(app: app)
        downloads.showRow(seriesID: UITestFixtureIdentity.seriesID).awaitExistence("the show's row").tap()
        downloads.episodeRow(itemID: e2).awaitExistence("S2:E2 on the show's page").tap()
        assertOpenDownloadReadsVersion("Extended Edition")
    }

    /// Dismissing either question downloads nothing: the button is back to
    /// its idle Download Season.
    func test_seasonDownload_cancel_startsNothing() {
        let detail = openShowWithVersions()
        detail.seasonDownloadButton.awaitExistence("the season's download button").tap()
        let option = detail.bulkVersionOption(0)
        option.awaitExistence("the season's version question")
        detail.dismissVersionQuestion()
        option.awaitDisappearance("the season's version question")
        assertSeasonDownloadIdle(detail, "after the single question's dismissal")

        detail.selectSeason("season-2")
        detail.seasonDownloadButton.tap()
        detail.bulkCancelButton.awaitExistence("the per-episode sheet's Cancel").tap()
        detail.bulkRowPicker(UITestFixtureIdentity.episodeID(season: 2, episode: 1))
            .awaitDisappearance("the per-episode sheet")
        assertSeasonDownloadIdle(detail, "after the sheet's Cancel")
    }

    private func assertSeasonDownloadIdle(
        _ detail: AssetDetailScreen, _ when: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        // Long enough for a download to have started had the dismissal
        // carried on.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let button = detail.seasonDownloadButton
        XCTAssertTrue(button.isEnabled, "The button is idle again \(when)", file: file, line: line)
        XCTAssertFalse(button.label.localizedCaseInsensitiveContains("Downloading"), file: file, line: line)
        XCTAssertFalse(button.label.localizedCaseInsensitiveContains("Downloaded"), file: file, line: line)
    }
}
