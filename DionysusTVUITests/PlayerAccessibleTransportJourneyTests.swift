import XCTest

/// The accessible transport (M5), forced on: XCUITest can't run VoiceOver,
/// but the mode is the same, so the focus engine drives real buttons.
final class PlayerAccessibleTransportJourneyTests: TVUITestCase {
    private let accessible = ["-UITestAccessibleTransport", "YES"]

    private func control(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons[A11yID.TV.Player.control(id)]
    }

    /// Skip and Next Up sit above the right end of the icon row: Right to
    /// the last icon, then Up, then Right along the card if need be.
    private func reachAboveTheIcons(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        for _ in 0..<10 where !app.buttons[A11yID.TV.Player.icon("stats")].hasFocus { press(.right) }
        press(.up)
        return moveFocus(to: target, pressing: .right, limit: 2)
    }

    func test_opensOnPlayPause_pauses_andTheTransportNeverFades() {
        let app = openPlayer(extraArguments: accessible)
        let playPause = control(app, "playPause")
        XCTAssertTrue(waitForFocus(playPause), "Play/Pause takes focus as the player opens")
        let playingLabel = playPause.label
        press(.select)
        // Compared with each other, never with a localized literal.
        XCTAssertTrue(poll(timeout: 3) { playPause.label != playingLabel }, "Pausing relabels the button")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { playPause.label == playingLabel })
        // Playing again, and past the fade the remote's mode would apply.
        sleep(UInt32(5))
        XCTAssertTrue(playPause.exists, "The transport stays up while playing")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
    }

    func test_skipButtons_move10s() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.right)
        XCTAssertTrue(waitForFocus(control(app, "forward")))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= before + 9 }, "Forward skips 10s")
    }

    func test_scrubber_isAdjustable_andRightSkips() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        press(.down)
        let scrubber = app.descendants(matching: .any)[A11yID.TV.Player.scrubber]
        XCTAssertTrue(waitForFocus(scrubber))
        // XCUITest reports an adjustable SwiftUI element as Other, so its
        // swipe-up/down steps are checked by hand with VoiceOver; here, its
        // spoken position, which a skip changes.
        let spoken = scrubber.value as? String
        XCTAssertFalse(spoken?.isEmpty ?? true, "The scrubber reads its position")
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= before + 9 })
        XCTAssertNotEqual(scrubber.value as? String, spoken)
    }

    func test_audio_opensThePanel_choosesATrack_menuClosesThenLeaves() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        let audio = app.buttons[A11yID.TV.Player.icon("audio")]
        XCTAssertTrue(moveFocus(to: audio, pressing: .right, limit: 8))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 5))
        let second = app.buttons[A11yID.TV.Player.panelRow("audio", 1)]
        XCTAssertTrue(moveFocus(to: second, pressing: .down, limit: 4))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { second.isSelected }, "The chosen track is marked selected")
        press(.menu)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForFocus(control(app, "playPause")), "Focus returns to Play/Pause")
        press(.menu)
        XCTAssertTrue(app.buttons[A11yID.TV.Player.showControls].waitForExistence(timeout: 3), "…then the controls hide")
        press(.menu)
        XCTAssertFalse(app.buttons[A11yID.TV.Player.showControls].waitForExistence(timeout: 3), "…then the player closes")
    }

    /// Watching without the controls (Benjamin, 2026-10-08): Menu hides
    /// them, and Select, Up or Down brings them back with Play/Pause focused.
    func test_menuHidesTheControls_andSelectUpOrDownBringsThemBackOnPlayPause() {
        let app = openPlayer(extraArguments: accessible)
        let playPause = control(app, "playPause")
        let show = app.buttons[A11yID.TV.Player.showControls]
        XCTAssertTrue(waitForFocus(playPause))
        press(.right)
        for key in [XCUIRemote.Button.select, .up, .down] {
            press(.menu)
            XCTAssertTrue(waitForFocus(show), "Hidden, Show Player Controls holds focus")
            XCTAssertFalse(playPause.exists)
            sleep(5)
            XCTAssertFalse(playPause.exists, "Nothing brings them back by itself")
            press(key)
            XCTAssertTrue(waitForFocus(playPause), "\(key) brings them back on Play/Pause")
        }
    }

    func test_skipIntro_isAButton() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: accessible)
        let skip = app.buttons[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(reachAboveTheIcons(app, skip), "Up from the last icon reaches Skip")
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) > before + 15 }, "Skip jumps to the intro's end")
    }

    func test_nextUp_closeAndPlayNow_areButtons() {
        let app = openEpisodeOne(scenario: "earlyCredits", extraArguments: accessible)
        let close = app.buttons[A11yID.TV.Player.nextUpClose]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Player.nextUpPlayNow].exists)
        XCTAssertTrue(reachAboveTheIcons(app, close), "Up from the last icon reaches the card")
        press(.select)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 2))
    }

    /// Up from the scrubber always lands on Play/Pause (Benjamin,
    /// 2026-10-08), even arriving at it from the Stats icon on the far right.
    func test_upFromTheScrubber_alwaysLandsOnPlayPause() {
        let app = openPlayer(extraArguments: accessible)
        let playPause = control(app, "playPause")
        let scrubber = app.descendants(matching: .any)[A11yID.TV.Player.scrubber]
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertTrue(moveFocus(to: app.buttons[A11yID.TV.Player.icon("stats")], pressing: .right, limit: 10))
        press(.down)
        XCTAssertTrue(waitForFocus(scrubber))
        press(.up)
        XCTAssertTrue(waitForFocus(playPause), "From the scrubber, Up is Play/Pause, not the icon above")
        press(.down)
        press(.right)
        press(.up)
        XCTAssertTrue(waitForFocus(playPause))
    }

    /// Hidden, Left and Right still skip 10s and leave the controls hidden
    /// (Benjamin, 2026-10-08).
    func test_hidden_leftAndRightSkip_andTheControlsStayHidden() {
        let app = openPlayer(extraArguments: accessible)
        let playPause = control(app, "playPause")
        XCTAssertTrue(waitForFocus(playPause))
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Player.showControls]))
        press(.right)
        press(.right)
        press(.left)
        XCTAssertFalse(playPause.waitForExistence(timeout: 1), "The controls stay hidden")
        press(.up)
        XCTAssertTrue(waitForFocus(playPause))
        // +20 -10, plus the seconds played meanwhile.
        XCTAssertGreaterThanOrEqual(elapsedSeconds(app) ?? 0, before + 9)
    }
}
