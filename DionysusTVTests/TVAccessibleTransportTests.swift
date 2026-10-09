import XCTest
@testable import Dionysus

final class TVAccessibleTransportTests: XCTestCase {
    func test_onWithVoiceOverSwitchControlOrTheHarness() {
        XCTAssertFalse(TVAccessibleTransport.isOn(voiceOver: false, switchControl: false, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: true, switchControl: false, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: false, switchControl: true, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: false, switchControl: false, forced: true))
    }

    func test_announcements() {
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .pause), String(localized: "Paused"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .play), String(localized: "Playing"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .skipForward), String(localized: "Forward 10 seconds"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .skipBack), String(localized: "Back 10 seconds"))
        var context = TVPlayerContext()
        context.audioTrackIDs = [3, 4]
        context.audioTrackTitles = ["English", "French"]
        context.subtitleTrackIDs = [7]
        context.subtitleTrackTitles = ["English SDH"]
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectAudio(id: 4)], context: context), String(localized: "Audio, French"))
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectSubtitle(id: 7)], context: context), String(localized: "Subtitles, English SDH"))
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectSubtitle(id: nil)], context: context), String(localized: "Subtitles, Off"))
        XCTAssertNil(TVPlayerAnnouncement.trackChosen([.seek(0)], context: context))
    }
}
