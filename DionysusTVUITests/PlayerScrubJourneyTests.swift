import XCTest

final class PlayerScrubJourneyTests: TVUITestCase {
    private let keepTransportUp = ["-UITestDisableControlAutoHide", "YES"]

    /// The fixture movie has chapters and the fake engine two audio and three
    /// subtitle tracks, so three icons show; Stats waits for its setting.
    func test_icons_matchTheTitle_andUpLeftRightMenuMoveAmongThem() {
        let app = openPlayer(extraArguments: keepTransportUp)
        for id in ["chapters", "audio", "subtitles"] {
            XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon(id)].exists, "\(id) icon")
        }
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"))
        press(.up)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.chapters"))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.menu)
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"), "Menu takes focus back to the scrubber")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists, "…without closing the player")
    }

    func test_pausedRightThrice_previewsThirtySecondsOn_andSelectGoesThere() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.playPause)
        Thread.sleep(forTimeInterval: 1)
        let pausedAt = try XCTUnwrap(elapsedSeconds(app))
        press(.right, times: 3)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.scrubPreview].waitForExistence(timeout: 3))
        XCTAssertTrue(poll(timeout: 3) { abs((self.elapsedSeconds(app) ?? 0) - (pausedAt + 30)) <= 1 }, "The preview reads 30s on, still paused")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.scrubPreview].exists })
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= pausedAt + 31 }, "Select seeks there and plays")
    }

    /// Native-style scanning: holding Right pauses and scans at level 1;
    /// further presses step the level (to 32x at level 3) and back through
    /// a stop; Menu returns to where playback was and resumes.
    func test_holdingRight_scans_pressesStepTheLevel_andMenuReturns() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        let before = try XCTUnwrap(elapsedSeconds(app))
        XCUIRemote.shared.press(.right, forDuration: 1)
        let indicator = app.descendants(matching: .any)[A11yID.TV.Player.scanIndicator]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))
        XCTAssertEqual(indicator.value as? String, "1")
        press(.right, times: 2)
        XCTAssertTrue(poll(timeout: 3) { indicator.value as? String == "3" })
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(elapsedSeconds(app) ?? 0, before + 40, "32x for two seconds")
        press(.left, times: 3)
        XCTAssertTrue(poll(timeout: 3) { indicator.value as? String == "0" }, "Back through the levels to a stop")
        let stopped = elapsedSeconds(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(elapsedSeconds(app), stopped, "A stopped scan holds still")
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !indicator.exists })
        let resumed = try XCTUnwrap(elapsedSeconds(app))
        XCTAssertLessThan(abs(resumed - before), 6, "Back where playback was")
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) > resumed + 1 }, "…and playing again")
    }

    func test_playPauseAndSkips_flashAGlyph() {
        let app = openPlayer(extraArguments: keepTransportUp)
        let flash = app.descendants(matching: .any)[A11yID.TV.Player.actionFlash]
        press(.playPause)
        XCTAssertTrue(flash.waitForExistence(timeout: 2))
        press(.playPause)
        press(.right)
        XCTAssertTrue(flash.exists)
    }

}
