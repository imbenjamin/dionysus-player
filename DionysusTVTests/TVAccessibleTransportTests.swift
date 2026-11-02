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

    /// Subtitle titles spell out their abbreviations, as the rows do (M5 review).
    func test_subtitleAnnouncement_spellsOutFormats() {
        var context = TVPlayerContext()
        context.subtitleTrackIDs = [7]
        context.subtitleTrackTitles = ["English (CC)"]
        XCTAssertEqual(
            TVPlayerAnnouncement.trackChosen([.selectSubtitle(id: 7)], context: context),
            String(localized: "Subtitles, \(MediaItem.spokenFormats(in: "English (CC)"))")
        )
        XCTAssertNotEqual(MediaItem.spokenFormats(in: "English (CC)"), "English (CC)")
    }

    /// Next Up names the episode, not only the show already playing (M5 review).
    func test_nextUp_namesTheEpisode() {
        var dto = BaseItemDto(id: "e", name: "Alone in the Night", type: .episode)
        dto.seriesName = "Space Show"
        dto.parentIndexNumber = 1
        dto.indexNumber = 3
        let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)
        let episode = MediaItem(dto: dto, images: images)
        let spoken = String(localized: "season \(1) episode \(3)")
        XCTAssertEqual(TVPlayerAnnouncement.nextUp(episode), String(localized: "Up next: \("Space Show, \(spoken), Alone in the Night")"))
        let movie = MediaItem(dto: BaseItemDto(id: "m", name: "1917", type: .movie), images: images)
        XCTAssertEqual(TVPlayerAnnouncement.nextUp(movie), String(localized: "Up next: \("1917")"))
    }
}
