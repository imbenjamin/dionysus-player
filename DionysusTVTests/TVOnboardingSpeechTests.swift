import XCTest
@testable import Dionysus

/// What VoiceOver says on the way in: a Quick Connect code read a digit at a
/// time, and discovery saying it found a server.
final class TVOnboardingSpeechTests: XCTestCase {
    func test_spokenCode_isReadADigitAtATime() {
        XCTAssertEqual(TVOnboardingSpeech.spokenCode("123456"), "1 2 3 4 5 6")
    }

    func test_spokenCode_ofNothing_isNothing() {
        XCTAssertEqual(TVOnboardingSpeech.spokenCode(""), "")
    }

    func test_foundServers_isAnnouncedWhenTheListStopsBeingEmpty() {
        XCTAssertNotNil(TVOnboardingSpeech.foundServersAnnouncement(count: 1, previousCount: 0))
        XCTAssertNotNil(TVOnboardingSpeech.foundServersAnnouncement(count: 2, previousCount: 0))
    }

    func test_foundServers_isNotAnnouncedAgain_asMoreArrive_orWhenTheListEmpties() {
        XCTAssertNil(TVOnboardingSpeech.foundServersAnnouncement(count: 2, previousCount: 1))
        XCTAssertNil(TVOnboardingSpeech.foundServersAnnouncement(count: 0, previousCount: 2))
        XCTAssertNil(TVOnboardingSpeech.foundServersAnnouncement(count: 0, previousCount: 0))
    }

    func test_foundServers_saysOneAndSeveralDifferently() {
        XCTAssertNotEqual(
            TVOnboardingSpeech.foundServersAnnouncement(count: 1, previousCount: 0),
            TVOnboardingSpeech.foundServersAnnouncement(count: 2, previousCount: 0)
        )
    }

    func test_aScanThatEndsEmpty_saysSo() {
        XCTAssertNotNil(TVOnboardingSpeech.scanEndedAnnouncement(wasScanning: true, isScanning: false, serverCount: 0))
    }

    func test_aScanThatFoundServers_orIsStillRunning_saysNothingMore() {
        XCTAssertNil(TVOnboardingSpeech.scanEndedAnnouncement(wasScanning: true, isScanning: false, serverCount: 1))
        XCTAssertNil(TVOnboardingSpeech.scanEndedAnnouncement(wasScanning: false, isScanning: true, serverCount: 0))
        XCTAssertNil(TVOnboardingSpeech.scanEndedAnnouncement(wasScanning: false, isScanning: false, serverCount: 0))
    }
}
