import XCTest

/// Deeper Player coverage than `SmokeJourneyTests.testPlayingAndClosingAnItem`
/// — transport, the track picker, and the chapter picker.
///
/// All three run against `PreviewPlaybackEngine` (see `PlaybackEngineFactory`),
/// not real media — its canned, hardcoded audio/subtitle tracks (ids 0/1
/// either way) are what these tests select against, not anything from
/// `UITestFixtureLibrary`'s own `MediaSourceInfo`. And its
/// `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` are no-ops that never
/// flip a track's own `isSelected` back — real, deliberate limits of the
/// fake (`PlaybackEngineFactory`'s doc comment), not something a real
/// AetherEngine session would do. So these tests assert what the fake
/// *can* prove — a leaf's row list is reachable and tapping one dismisses
/// the picker, exactly like a real selection would — not that the
/// selection is retained afterwards.
final class PlayerJourneyTests: UITestCase {
    private func openPlayer() -> PlayerScreen {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

    func testSkipForwardAdvancesElapsedTime() {
        let player = openPlayer()

        let before = player.elapsedLabel.label
        player.skipForwardButton.tap()

        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", before),
            object: player.elapsedLabel
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [changed], timeout: Self.defaultTimeout), .completed,
            "Skipping forward should advance the elapsed-time label."
        )
    }

    /// Opens the track picker, drills into each leaf, and taps a row —
    /// proving the panel is drivable at all (root → leaf → dismiss) rather
    /// than the actual audio/subtitle decision, which `PreviewPlaybackEngine`
    /// doesn't track (see this file's doc comment).
    func testTrackPickerNavigatesBothLeavesAndDismissesOnSelection() {
        let player = openPlayer()

        player.tracksButton.tap()
        player.trackNavigationRow("audio").awaitExistence("the Audio navigation row")
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")

        player.trackNavigationRow("audio").tap()
        let audioOption = player.trackOption("audio", 1)
        audioOption.awaitExistence("the second audio track row")
        audioOption.tap()
        audioOption.awaitDisappearance("the track picker after selecting an audio track")

        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        player.subtitleOffOption.awaitExistence("the subtitle leaf's Off row")
        player.subtitleOffOption.tap()
        player.subtitleOffOption.awaitDisappearance("the track picker after selecting a subtitle track")
    }

    /// Opens the chapter picker (the fixture movie has four, see
    /// `UITestFixtureLibrary.chapters(runtimeMinutes:)`) and selects one.
    func testChapterPickerOpensAndSelectingADismissesIt() {
        let player = openPlayer()

        player.chaptersButton.tap()
        player.chapterPicker.awaitExistence("the chapter picker")
        let secondChapter = player.chapterOption(1)
        secondChapter.awaitExistence("the second chapter row")
        secondChapter.tap()

        player.chapterPicker.awaitDisappearance("the chapter picker after selecting a chapter")
    }
}
