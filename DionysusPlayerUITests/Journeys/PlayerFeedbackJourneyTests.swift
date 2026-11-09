import XCTest

/// What the player shows about states the fake engine and stub otherwise
/// never reach (TQ-14): the scrub bubble's trickplay still, "Reconnecting…"
/// while the source is retried, and Picture in Picture's button and
/// placeholder. Each runs under its own scenario (`scrubThumbnails`,
/// `reconnecting`, `pictureInPicture`), so no other journey changes.
///
/// PiP is checked by tap only: there's no AVKit window under the fake engine,
/// which reports PiP active when asked and inactive 3 s later, as a return
/// from the system's window would.
final class PlayerFeedbackJourneyTests: UITestCase {
    private func openPlayer(scenario: String) -> PlayerScreen {
        launch(scenario: scenario)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

    /// Drags from the scrubber's middle to `fraction` and holds there, long
    /// enough for the throttled fetch to land, before lifting.
    private func scrubAndHold(_ player: PlayerScreen, to fraction: CGFloat) {
        let scrubber = player.scrubber
        scrubber.awaitExistence("the scrubber")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 1.5
        )
    }

    private func awaitScrubPreview(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.descendants(matching: .any)[A11yID.UITest.lastScrubPreview]
        let shown = NSPredicate(format: "label == %@", expected)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: probe)], timeout: 10)
        XCTAssertEqual(result, .completed,
                       "The scrub bubble should have shown \(expected), not \(probe.exists ? probe.label : "nothing")",
                       file: file, line: line)
    }

    /// The bubble shows the tile for where the finger is: the first tile at
    /// the start, the last near the end (`UITestTrickplay`), each cropped to
    /// one 320×180 still from its sheet.
    func testScrubBubble_showsTheTrickplayStillForThePosition() {
        let player = openPlayer(scenario: "scrubThumbnails")
        scrubAndHold(player, to: 0)
        awaitScrubPreview("320×180 red")
        // Short of the end: a seek to the very end ends playback.
        scrubAndHold(player, to: 0.9)
        awaitScrubPreview("320×180 yellow")
    }

    /// A dropped source says so under the spinner, then playback carries on.
    func testReconnecting_isNamedUnderTheSpinner_untilPlaybackResumes() {
        let player = openPlayer(scenario: "reconnecting")
        player.reconnectingLabel.awaitExistence("Reconnecting…")
        XCTAssertFalse(player.playPauseButton.exists, "The spinner replaces the play button while reconnecting")
        player.reconnectingLabel.awaitDisappearance("Reconnecting… once playback resumes")
        player.playPauseButton.awaitExistence("the play button back after reconnecting")
    }

    /// Without PiP possible (the fake engine's default, as AetherEngine's
    /// software route) the button is left out rather than disabled.
    func testPictureInPictureButton_isLeftOutWhenPiPIsUnavailable() {
        let player = openPlayer(scenario: "standard")
        player.tracksButton.awaitExistence("the top row's tracks button")
        XCTAssertFalse(player.pictureInPictureButton.exists)
    }

    /// The button hands the picture to PiP: the placeholder covers the
    /// surface and the controls go with it; back from PiP, they return.
    func testPictureInPictureButton_coversThePlayer_untilPiPEnds() {
        let player = openPlayer(scenario: "pictureInPicture")
        player.pictureInPictureButton.awaitExistence("the Picture in Picture button")
        player.pictureInPictureButton.tap()
        player.pictureInPictureOverlay.awaitExistence("the Picture in Picture placeholder")
        // Not asserted: the controls hiding. Faded, they stay in XCUITest's
        // tree with no hit point, and asking `isHittable` then raises
        // rather than answering false.

        player.pictureInPictureOverlay.awaitDisappearance("the placeholder once PiP ends")
        // Back, the controls read as unhittable to XCUITest even once
        // visible (as in `VoiceOverJourneyTests`), so a tap on Close's spot
        // proves them: on hidden controls it would only reveal them.
        player.closeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        player.closeButton.awaitDisappearance("the player, closed from its restored controls")
    }
}
