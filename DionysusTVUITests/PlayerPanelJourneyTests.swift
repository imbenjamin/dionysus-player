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

    // MARK: Night

    /// From the scrubber: the panel on Info, Right along to Night (after
    /// Subtitles), Down onto Night Mode.
    private func openNightTab(_ app: XCUIApplication) {
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        press(.right, times: 4)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.night"))
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.night.0"))
    }

    /// The schedule switching Night Mode mid-play says so over the picture,
    /// and the switch applies. The harness stands in for the boundary
    /// (`-UITestNightModeScheduledSwitchAfter`); the levels stay at their
    /// defaults, since launch arguments don't reach the shared keychain, so
    /// Night Audio is what the stats row shows.
    func test_scheduledSwitch_saysSo_andApplies() {
        let app = launch(scenario: "standard", seedSession: true, extraArguments: keepTransportUp + [
            "-UITestNightModeScheduledSwitchAfter", "4"
        ])
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
        app.open(URL(string: "dionysus://play/\(UITestFixtureIdentity.primaryMovieID)?stats=1")!)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.statsPanel].waitForExistence(timeout: 10))
        let notice = app.descendants(matching: .any)[A11yID.Player.nightModeNotice]
        let statsRow = app.descendants(matching: .any)[A11yID.TV.Player.statsValue("Night Mode")]

        XCTAssertTrue(notice.waitForExistence(timeout: 15), "The scheduled switch's notice")
        XCTAssertEqual(notice.label, "Night Mode starting as scheduled")
        XCTAssertTrue(statsRow.waitForExistence(timeout: 5))
        XCTAssertEqual(statsRow.value as? String, "Night Audio")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nightIndicator].exists, "The moon by the time")
        XCTAssertTrue(poll(timeout: 8) { !notice.exists }, "The notice leaves on its own")
    }

    /// The dimming layer has no identifier (it's hidden from accessibility),
    /// so its level is read from Playback Stats' "Night Mode" row, opened by
    /// the play link (`TESTING.md`, deep links).
    func test_nightTab_dimsAndShowsInStats() {
        let app = launch(scenario: "standard", seedSession: true, extraArguments: keepTransportUp)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
        app.open(URL(string: "dionysus://play/\(UITestFixtureIdentity.primaryMovieID)?stats=1")!)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.statsPanel].waitForExistence(timeout: 10))
        let statsRow = app.descendants(matching: .any)[A11yID.TV.Player.statsValue("Night Mode")]
        let indicator = app.descendants(matching: .any)[A11yID.TV.Player.nightIndicator]
        XCTAssertFalse(statsRow.exists, "Off, Night Mode has no row")
        XCTAssertFalse(indicator.exists)

        openNightTab(app)
        let toggle = app.descendants(matching: .any)[A11yID.TV.Player.nightToggle]
        XCTAssertEqual(toggle.value as? String, "Off")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (toggle.value as? String) == "On" })
        XCTAssertTrue(indicator.waitForExistence(timeout: 3), "The moon by the time")

        // Into Volume Limit on its −, then down to Brightness's −
        // (`TVNightPanelRow.all`: 3 and 7).
        press(.down, times: 2)
        XCTAssertTrue(waitForPlayerFocus(app, "content.night.3"))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nightControl("volume", "decrease")].exists)
        let volume = app.descendants(matching: .any)[A11yID.TV.Player.nightVolume]
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (volume.value as? String) == "95%" })
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.night.7"))
        let brightness = app.descendants(matching: .any)[A11yID.TV.Player.nightBrightness]
        press(.select, times: 2)
        XCTAssertTrue(poll(timeout: 3) { (brightness.value as? String) == "90%" })

        // Stats give way to the panel; Menu closes it and they're back.
        press(.menu)
        XCTAssertTrue(statsRow.waitForExistence(timeout: 5))
        XCTAssertEqual(statsRow.value as? String, "Night Audio · Volume 95% · Brightness 90%")

        // Brightness's 0%, left of its −: a black picture with sound.
        openNightTab(app)
        press(.down, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "content.night.7"))
        press(.left)
        XCTAssertTrue(waitForPlayerFocus(app, "content.night.6"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (brightness.value as? String) == "0%" })
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { (statsRow.value as? String) == "Night Audio · Volume 95% · Brightness 0%" })
    }
}
