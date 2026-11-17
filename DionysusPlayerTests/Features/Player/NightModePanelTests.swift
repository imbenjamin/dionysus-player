import XCTest
@testable import Dionysus

/// The iOS player's Night panel: what each level control does, which ones
/// are inert, and the panel's two pieces of copy.
final class NightModePanelTests: XCTestCase {
    func test_controls_stepFiveAndJumpToTheEnds() {
        XCTAssertEqual(NightModePanel.target(of: .decrease, from: 60), 55)
        XCTAssertEqual(NightModePanel.target(of: .increase, from: 60), 65)
        XCTAssertEqual(NightModePanel.target(of: .min, from: 60), 0)
        XCTAssertEqual(NightModePanel.target(of: .max, from: 60), 100)
    }

    func test_controls_stayWithinTheRange() {
        XCTAssertEqual(NightModePanel.target(of: .decrease, from: 0), 0)
        XCTAssertEqual(NightModePanel.target(of: .increase, from: 100), 100)
    }

    /// − and 0% do nothing at 0%; + and 100% nothing at 100%.
    func test_aControlThatWouldDoNothingIsInert() {
        XCTAssertTrue(NightModePanel.isInert(.min, percent: 0))
        XCTAssertTrue(NightModePanel.isInert(.decrease, percent: 0))
        XCTAssertFalse(NightModePanel.isInert(.increase, percent: 0))
        XCTAssertFalse(NightModePanel.isInert(.max, percent: 0))

        XCTAssertFalse(NightModePanel.isInert(.min, percent: 100))
        XCTAssertFalse(NightModePanel.isInert(.decrease, percent: 100))
        XCTAssertTrue(NightModePanel.isInert(.increase, percent: 100))
        XCTAssertTrue(NightModePanel.isInert(.max, percent: 100))

        for control in NightModePanel.Control.allCases {
            XCTAssertFalse(NightModePanel.isInert(control, percent: 50))
        }
    }

    func test_nightAudioNote_isTheFixedCopyOrUnavailable() {
        let note = "Limits dynamic range. Turns off Atmos and passthrough while on."
        XCTAssertEqual(NightModePanel.nightAudioNote(.off), note)
        XCTAssertEqual(NightModePanel.nightAudioNote(.applied), note)
        XCTAssertEqual(NightModePanel.nightAudioNote(.unavailable), "Not available when transcoding")
    }

    func test_scheduleSummary_showsTheWindowOrOff() {
        let locale = Locale(identifier: "en_GB")
        var schedule = NightModeSettings.defaults.schedule
        XCTAssertEqual(NightModePanel.scheduleSummary(schedule, locale: locale), "Schedule: Off")
        schedule.isEnabled = true
        XCTAssertEqual(NightModePanel.scheduleSummary(schedule, locale: locale), "Schedule: 22:00–07:00")
        // Equal times never open a window, so there is nothing to summarise.
        schedule.turnOff = schedule.turnOn
        XCTAssertEqual(NightModePanel.scheduleSummary(schedule, locale: locale), "Schedule: Off")
    }

    /// 12- or 24-hour follows the locale, as the Profile pickers do.
    func test_scheduleSummary_followsTheLocalesClock() {
        var schedule = NightModeSettings.defaults.schedule
        schedule.isEnabled = true
        let summary = NightModePanel.scheduleSummary(schedule, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(summary.contains("10:00"), summary)
        XCTAssertTrue(summary.contains("PM"), summary)
    }
}
