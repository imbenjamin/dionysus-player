import XCTest
@testable import Dionysus

/// The centred glyph that confirms play, pause and a 10s skip
/// (Benjamin, 2026-10-06), and the knob on a focused scrubber.
final class TVPlayerFlashTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerFlashTests.standardContext
    var now: TimeInterval = 1000

    func test_playPause_flashesWhatItDid() {
        send(.playPause)
        XCTAssertEqual(state.flash?.kind, .pause, "Playing, so the toggle pauses")
        context.playback = .paused
        let serial = state.flash?.serial
        send(.select)
        XCTAssertEqual(state.flash?.kind, .play)
        XCTAssertNotEqual(state.flash?.serial, serial, "Each action is a new flash")
    }

    func test_skips_flashTheirDirection() {
        press(.right)
        XCTAssertEqual(state.flash?.kind, .skipForward)
        press(.left)
        XCTAssertEqual(state.flash?.kind, .skipBack)
    }

    func test_committingAScrub_flashesPlay() {
        context.playback = .paused
        press(.right)
        state.flash = nil
        send(.select)
        XCTAssertEqual(state.flash?.kind, .play)
    }

    func test_theKnobShows_whileTheScrubberHasFocus() {
        XCTAssertTrue(TVPlayerInputModel.scrubberHasFocus(state))
        send(.up)
        XCTAssertFalse(TVPlayerInputModel.scrubberHasFocus(state))
        state.chrome = .hidden
        XCTAssertFalse(TVPlayerInputModel.scrubberHasFocus(state))
    }
}
