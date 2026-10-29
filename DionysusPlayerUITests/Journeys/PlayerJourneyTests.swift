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

    /// Both skips jump 10s, as the Apple TV's do (Benjamin, 2026-10-07; they
    /// were 15s back and 30s forward). Read off the scrubber's value, the
    /// unlocalized "m:ss" position; the fake engine plays on at 1x, so the
    /// bounds leave room for a few seconds of playback, never for 30.
    func testSkipButtonsJumpTenSeconds() {
        let player = openPlayer()
        func position() -> Double? {
            let parts = ((player.scrubber.value as? String) ?? "").split(separator: ":").compactMap { Double($0) }
            return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
        }
        func waitForPosition(_ range: ClosedRange<Double>, _ message: String) {
            let reached = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in position().map(range.contains) ?? false },
                object: nil
            )
            XCTAssertEqual(XCTWaiter().wait(for: [reached], timeout: 5), .completed, message)
        }
        guard let start = position() else { return XCTFail("Unreadable scrubber value") }

        player.skipForwardButton.tap()
        waitForPosition((start + 9)...(start + 15), "Forward skips 10s on from \(start)s")
        guard let ahead = position() else { return XCTFail("Unreadable scrubber value") }

        player.skipBackwardButton.tap()
        waitForPosition((ahead - 11)...(ahead - 5), "Back skips 10s from \(ahead)s")
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

    /// The offset, a page of its own under Audio when there's a track to
    /// choose too: + steps 10 ms, Reset (shown only under This Title) goes
    /// back to the global value, All Titles edits the global value, and a
    /// title's own offset survives a relaunch.
    func testAudioOffsetStepsScopesResetsAndIsRemembered() {
        let player = openPlayer()
        player.tracksButton.tap()
        player.trackNavigationRow("audio").tap()
        player.trackOption("audio", 1).awaitExistence("the Audio page's tracks")
        // Parked beside the panel, the page is built but out of reach, as the
        // leaf page is beside the root, and hidden from VoiceOver: on a window
        // wide enough (a closed iPhone Duo's) its frame fell inside it.
        XCTAssertFalse(player.audioOffsetValue.exists, "The offset is a page of its own, not under the tracks")
        player.trackNavigationRow("audioOffset").tap()
        let value = player.audioOffsetValue
        value.awaitExistence("the audio offset row")
        XCTAssertEqual(value.value as? String, "0 milliseconds, in sync")
        player.audioOffsetIncrease.tap()
        player.audioOffsetIncrease.tap()
        XCTAssertEqual(value.value as? String, "20 milliseconds, audio later")
        XCTAssertTrue(player.audioOffsetReset.isEnabled)
        player.audioOffsetReset.tap()
        XCTAssertEqual(value.value as? String, "0 milliseconds, in sync")

        player.audioOffsetScope("allTitles").tap()
        player.audioOffsetReset.awaitDisappearance("Reset, which only This Title shows")
        player.audioOffsetScope("thisTitle").tap()
        player.audioOffsetReset.awaitExistence("Reset, back under This Title")
        player.audioOffsetIncrease.tap()
        XCTAssertEqual(value.value as? String, "10 milliseconds, audio later")
        player.audioOffsetBack.tap()
        player.trackOption("audio", 1).awaitExistence("the Audio page, back from Audio Offset")

        app.terminate()
        launch(resetsState: false)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let again = PlayerScreen(app: app)
        again.awaitControls()
        again.tracksButton.tap()
        again.trackNavigationRow("audio").tap()
        again.trackNavigationRow("audioOffset").tap()
        again.audioOffsetValue.awaitExistence("the audio offset row after a relaunch")
        XCTAssertEqual(again.audioOffsetValue.value as? String, "10 milliseconds, audio later", "The title kept its offset")
    }

    func testAudioOffsetHiddenWhenUnavailable() {
        launch(scenario: "audioOffsetUnavailable")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.tracksButton.tap()
        player.trackNavigationRow("audio").tap()
        player.trackOption("audio", 0).awaitExistence("the first audio track")
        XCTAssertFalse(player.audioOffsetValue.exists)
        XCTAssertFalse(player.trackNavigationRow("audioOffset").exists)
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
        // Read from the player window's screen rather than canned, so these
        // only prove that screen was found ("—" when it isn't).
        XCTAssertNotEqual(player.statsValue("Screen").label, "—")
        XCTAssertNotEqual(player.statsValue("Refresh Rate").label, "—")

        // The panel sits beneath the controls, so while they're up the first
        // tap lands on their blank-space catcher and hides them, as it would
        // for anyone, and pages turn from the second tap on. On an iPhone Duo
        // in tabletop the controls sit below the fold, clear of the panel
        // above it, so the first tap turns the page.
        player.statsPageIndicator.tap()
        let turnedByFirstTap = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "2/3"),
            object: player.statsPageIndicator
        )
        let pages = XCTWaiter().wait(for: [turnedByFirstTap], timeout: 2) == .completed
            ? ["3/3", "1/3", "2/3"]
            : ["2/3", "3/3", "1/3"]
        for expected in pages {
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

    /// Locking rotation in landscape holds the app there when the device turns
    /// back upright. `RotationLock` reads the orientation to hold from the
    /// scene's `effectiveGeometry`; a lock that read nothing would leave the
    /// app free to follow the device. Skipped where the button is omitted
    /// (a resizable iPad app can't lock; `RotationLock.isSupported`), and on
    /// the iPhone Duo, which `XCUIDevice` can't turn.
    func testRotationLockHoldsLandscapeWhenTheDeviceTurnsUpright() throws {
        try skipWhereXCUIDeviceCannotRotate()
        let device = XCUIDevice.shared
        addTeardownBlock { @MainActor in device.orientation = .portrait }
        let player = openPlayer()
        guard player.rotationLockButton.waitForExistence(timeout: 2) else {
            throw XCTSkip("The rotation lock is omitted on this device.")
        }
        func isLandscape() -> Bool {
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        func wait(untilLandscape landscape: Bool, _ message: String) {
            let reached = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in isLandscape() == landscape },
                object: nil
            )
            XCTAssertEqual(XCTWaiter().wait(for: [reached], timeout: Self.defaultTimeout), .completed, message)
        }

        device.orientation = .landscapeLeft
        wait(untilLandscape: true, "The app should follow the device into landscape.")
        player.rotationLockButton.tap()

        device.orientation = .portrait
        // Give the app the time it would take to rotate, then check it didn't.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        XCTAssertTrue(isLandscape(), "The lock should hold landscape with the device upright.")

        player.rotationLockButton.tap()
        wait(untilLandscape: false, "Unlocking should let the app follow the device upright.")
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
