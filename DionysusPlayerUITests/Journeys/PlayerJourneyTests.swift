import XCTest

/// Deeper Player coverage than `SmokeJourneyTests.testPlayingAndClosingAnItem`
/// — transport, the track picker, the chapter picker, and Stats for Nerds.
///
/// All of them run against `PreviewPlaybackEngine` (see `PlaybackEngineFactory`),
/// not real media — its canned, hardcoded audio/subtitle tracks (ids 0/1
/// either way) are what these tests select against, not anything from
/// `UITestFixtureLibrary`'s own `MediaSourceInfo`. So these tests assert what
/// the fake can prove — a leaf's row list is reachable and tapping one
/// dismisses the picker, exactly like a real selection would.
///
/// The fake's `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` were once
/// no-ops that never flipped `isSelected`; they now track the selection,
/// because the authored-ASS path hangs off the subtitle one and would
/// otherwise be unreachable from a UI test (see
/// `StyledSubtitleJourneyTests`). What the fake still gives up is decode,
/// HDR, transcode and seek behaviour — `PlaybackEngineFactory`'s doc
/// comment has the full list.
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

    /// Opens Stats for Nerds and pages through all three pages and back to
    /// the first, reading one row from each. The values are
    /// `PreviewPlaybackEngine`'s canned stats, so this proves the panel lays
    /// out and pages, not what AetherEngine reports; `StreamFormatDescription`
    /// has the unit tests for that.
    ///
    /// The page counter is the proof of paging, not which rows resolve: every
    /// page stays mounted to keep the box a constant size, and XCUITest
    /// reaches the hidden ones' rows too.
    func testStatsPanelPagesThroughAllThreePages() {
        let player = openPlayer()

        player.statsButton.tap()
        player.statsPageIndicator.awaitExistence("the stats panel's page counter")
        XCTAssertEqual(player.statsPageIndicator.label, "1/3")
        XCTAssertEqual(player.statsValue("Codec").label, "HEVC Main 10")
        XCTAssertEqual(player.statsValue("Pixel Format").label, "yuv420p10le (10-bit)")
        XCTAssertEqual(player.statsValue("Sampling").label, "48 kHz")
        XCTAssertEqual(player.statsValue("Frames").label, "0 dropped")

        // The panel sits beneath the controls, so while they're up the first
        // tap lands on their blank-space catcher and hides them, as it would
        // for anyone. Pages turn from the second tap on.
        player.statsPageIndicator.tap()
        for expected in ["2/3", "3/3", "1/3"] {
            player.statsPageIndicator.tap()
            let turned = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", expected),
                object: player.statsPageIndicator
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [turned], timeout: Self.defaultTimeout), .completed,
                "Tapping the panel should turn to page \(expected)."
            )
        }
    }

    /// A movie has nothing queued after it, so reaching the end closes the
    /// player back to its detail page rather than holding on the last frame.
    func testReachingTheEndWithNothingQueuedReturnsToDetail() {
        let player = openPlayer()

        player.scrubToEnd()

        player.closeButton.awaitDisappearance("the player once playback ended")
        AssetDetailScreen(app: app).awaitLoaded()
    }
}
