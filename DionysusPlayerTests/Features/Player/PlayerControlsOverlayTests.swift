import XCTest
@testable import Dionysus

final class PlayerControlsOverlayTests: XCTestCase {
    /// The buttons and VoiceOver's adjustable action share one step, 10s
    /// each way (M4 review: VoiceOver's forward step had stayed at 15s).
    func test_skipStepsTenSecondsEachWay() {
        XCTAssertEqual(PlayerControlsOverlay.skipSeconds, 10)
        XCTAssertEqual(PlayerControlsOverlay.skipped(from: 100, by: 1, duration: 600), 110)
        XCTAssertEqual(PlayerControlsOverlay.skipped(from: 100, by: -1, duration: 600), 90)
    }

    func test_skipStaysWithinTheTitle() {
        XCTAssertEqual(PlayerControlsOverlay.skipped(from: 4, by: -1, duration: 600), 0)
        XCTAssertEqual(PlayerControlsOverlay.skipped(from: 595, by: 1, duration: 600), 600)
    }
}
