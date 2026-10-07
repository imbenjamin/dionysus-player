import XCTest

final class PlayerStatsJourneyTests: TVUITestCase {
    /// The setting's default is on in debug builds (iOS's), so the journey
    /// turns it off itself.
    func test_statsIcon_isAbsentWhileTheSettingIsOff() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "NO"])
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon("chapters")].exists)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.icon("stats")].exists)
    }

    /// The icon toggles the panel; Menu and Select don't close it.
    func test_statsIcon_togglesThePanel_whichIgnoresMenuAndSelect() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "YES"])
        press(.up)
        press(.right, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"))
        press(.select)
        let panel = app.descendants(matching: .any)[A11yID.TV.Player.statsPanel]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let codec = app.descendants(matching: .any)[A11yID.TV.Player.statsValue("Codec")]
        XCTAssertTrue(codec.waitForExistence(timeout: 3))
        XCTAssertEqual(codec.value as? String, "HEVC Main 10")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon("stats")].isSelected, "The icon shows it's on")
        press(.menu)
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"))
        press(.select)
        XCTAssertTrue(panel.exists, "Neither Menu nor Select closes it")
        press(.up)
        press(.right, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !panel.exists })
    }
}
