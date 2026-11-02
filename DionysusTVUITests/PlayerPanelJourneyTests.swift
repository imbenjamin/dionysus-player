import XCTest

final class PlayerPanelJourneyTests: TVUITestCase {
    private let keepTransportUp = ["-UITestDisableControlAutoHide", "YES"]

    func test_down_opensInfo_andRestartGoesBackToTheStart() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.infoArt].exists)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.info.0"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.panel].exists })
        XCTAssertTrue(poll(timeout: 3) { (self.elapsedSeconds(app) ?? 999) < 10 }, "Restart plays from 0:00")
    }

    func test_chapters_iconOpensOnTheCurrentChapter_andSelectJumpsThere() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.chapters"))
        press(.select)
        // The movie resumes at 20:00, inside its first chapter (0:00–23:45).
        XCTAssertTrue(waitForPlayerFocus(app, "content.chapters.0"))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "content.chapters.1"))
        let tile = app.descendants(matching: .any)[A11yID.TV.Player.panelRow("chapters", 1)]
        let start = try XCTUnwrap(Self.seconds(tile.value as? String ?? ""))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { abs((self.elapsedSeconds(app) ?? 0) - start) < 3 }, "Playback jumps to the chapter")
    }

    func test_audio_selectMovesTheTick_andTheChoiceIsRememberedNextTime() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        press(.down)
        press(.select)
        let second = app.descendants(matching: .any)[A11yID.TV.Player.panelRow("audio", 1)]
        XCTAssertTrue(poll(timeout: 3) { second.isSelected }, "The tick moves to the chosen track")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].exists, "The panel stays open")

        // Close the panel, hide the transport, close the player, and play
        // the same title again.
        press(.menu, times: 3)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(waitForFocus(play))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.up)
        press(.right)
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { app.descendants(matching: .any)[A11yID.TV.Player.panelRow("audio", 1)].isSelected })
    }

    func test_choosingASubtitle_showsItAboveTheRaisedScrubber() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.subtitles"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.subtitles.0"), "Off is chosen, so focus lands on it")
        press(.down)
        press(.select)
        let cue = app.descendants(matching: .any)[A11yID.Player.plainSubtitle].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        let scrubber = app.descendants(matching: .any)[A11yID.TV.Player.transport]
        XCTAssertLessThanOrEqual(cue.frame.maxY, scrubber.frame.minY, "The cue sits above the raised scrubber")
    }

    /// Subtitle Style through the player: System draws the system
    /// caption style (`SystemCaptionStyle.uiTestStyle` standing in for the
    /// Simulator's settings, twice the size), Dionysus doesn't.
    func test_subtitleAppearance_matchSystemFollowsTheSystemStyle_andDionysusDoesNot() {
        let customSystemStyle = keepTransportUp + ["-UITestCustomCaptionStyle", "YES"]
        let system = subRipCueHeight(openPlayer(extraArguments: customSystemStyle))
        let dionysus = subRipCueHeight(openPlayer(extraArguments: customSystemStyle + ["-subtitleAppearance", "dionysus"]))
        XCTAssertGreaterThan(system, dionysus * 1.5, "Twice the size (\(system) against \(dionysus))")
    }

    private func subRipCueHeight(_ app: XCUIApplication) -> CGFloat {
        press(.up)
        press(.right)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.subtitles"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.subtitles.0"))
        press(.down)
        press(.select)
        let cue = app.descendants(matching: .any)[A11yID.Player.plainSubtitle].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        return cue.frame.height
    }

    func test_choosingTheStyledTrack_rendersItThroughLibass() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.right)
        press(.select)
        press(.down, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "content.subtitles.3"))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.Player.styledSubtitle].waitForExistence(timeout: 10))
    }

    func test_menu_closesThePanel_thenHidesTheTransport_thenClosesThePlayer() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.panel].exists })
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !app.staticTexts[A11yID.TV.Player.elapsed].exists }, "A second Menu hides the transport")
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "A third closes the player")
    }

    func test_audioOffset_stepsScopesAndResets() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.3"), "Right from a track lands on the offset row")
        let row = app.descendants(matching: .any)[A11yID.TV.Player.audioOffsetRow]
        XCTAssertEqual(row.value as? String, "0 milliseconds, in sync")
        press(.right)
        press(.right)
        XCTAssertTrue(poll(timeout: 3) { (row.value as? String) == "20 milliseconds, audio later" })
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.4"), "Reset is reachable once the title has its own offset")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (row.value as? String) == "0 milliseconds, in sync" })
    }

    func test_audioOffset_hiddenWhenUnavailable() {
        let app = openPlayer(scenario: "audioOffsetUnavailable", extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.audioOffsetRow].exists)
    }
}
