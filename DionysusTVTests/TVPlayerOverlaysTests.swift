import XCTest
@testable import Dionysus

final class TVPlayerOverlaysTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerOverlaysTests.standardContext
    var now: TimeInterval = 1000
    let intro = TVPlayerContext.SkipSegment(id: "intro", endSeconds: 120)

    func test_select_skips_whileTheButtonShows() {
        context.skipSegment = intro
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
        state.chrome = .hidden
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
        XCTAssertEqual(send(.playPause), [.togglePlayPause], "Play/Pause still pauses")
    }

    func test_select_onAnIcon_isTheIcons_notASkip() {
        context.skipSegment = intro
        context.statsButtonEnabled = true
        send(.up)
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.stats))
        XCTAssertEqual(send(.select), [])
        XCTAssertTrue(state.isStatsOn)
    }

    func test_menu_hidesTheButtonWhileNothingElseIsUp_andASecondMenuCloses() {
        context.skipSegment = intro
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.hiddenSkipSegmentID, "intro")
        XCTAssertFalse(TVPlayerInputModel.skipButtonVisible(state, context: context))
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_aHiddenButton_returnsWithTheTransport_andSelectStillSkips() {
        context.skipSegment = intro
        state.chrome = .hidden
        send(.menu)
        send(.up)
        XCTAssertTrue(TVPlayerInputModel.skipButtonVisible(state, context: context))
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
    }

    func test_menuWithTheTransportUp_closes_evenWithTheButtonShowing() {
        context.skipSegment = intro
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_nextUp_hasFocusWhileTheTransportIsHidden() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertTrue(TVPlayerInputModel.nextUpHasFocus(state, context: context))
        XCTAssertEqual(press(.right), [], "Moves to Close instead of skipping")
        XCTAssertEqual(state.nextUpFocus, .close)
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(send(.select), [.dismissNextUp])
        press(.left)
        XCTAssertEqual(send(.select), [.playNext])
    }

    func test_nextUp_menuMeansClose() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [.dismissNextUp])
    }

    func test_nextUp_upShowsTheTransport_andTheCardLosesFocusUntilItFades() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        send(.up)
        XCTAssertFalse(TVPlayerInputModel.nextUpHasFocus(state, context: context))
        XCTAssertEqual(press(.right), [.seek(110)], "With the transport up, Right skips again")
        tick(for: 4.2)
        XCTAssertTrue(TVPlayerInputModel.nextUpHasFocus(state, context: context))
    }

    func test_nextUp_pausedArrowsMoveTheCard_notAScrub() {
        context.nextUpSecondsRemaining = 8
        context.playback = .paused
        state.chrome = .hidden
        // Pausing shows the transport on the next tick, so press before it.
        XCTAssertEqual(press(.right), [])
        XCTAssertNil(state.scrub)
    }

    func test_countdownReachingZero_playsNext_once() {
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [.playNext])
    }

    /// Review Focus 2.
    func test_countdownReachingZeroDuringAScrub_waitsForTheScrubToResolve() {
        context.nextUpSecondsRemaining = 3
        XCTAssertEqual(send(.swipeStep(.right)), [.pause], "A swipe while playing starts a scan")
        context.playback = .paused
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [])
        send(.menu)
        context.playback = .playing
        XCTAssertEqual(tick(for: 1), [.playNext])
    }

    func test_theCardsFocus_resetsWhenItGoes() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        press(.right)
        context.nextUpSecondsRemaining = nil
        tick(for: 0.1)
        XCTAssertEqual(state.nextUpFocus, .playNow)
    }
}
