import XCTest
@testable import Dionysus

final class TVPlayerOverlaysTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerOverlaysTests.standardContext
    var now: TimeInterval = 1000
    let intro = TVPlayerContext.SkipSegment(id: "intro", endSeconds: 120)

    func test_transportHidden_selectSkips() {
        context.skipSegment = intro
        state.chrome = .hidden
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "skip")
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
        state.chrome = .hidden
        XCTAssertEqual(send(.playPause), [.togglePlayPause], "Play/Pause still pauses")
    }

    /// With the transport up, Skip is its own stop above the icons
    /// (Benjamin, 2026-10-07): the scrubber alone has focus, and Select there
    /// plays or pauses.
    func test_transportUp_theScrubberAloneHasFocus_andSelectPauses() {
        context.skipSegment = intro
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "scrubber")
        XCTAssertFalse(TVPlayerInputModel.selectSkips(state, context: context))
        XCTAssertEqual(send(.select), [.togglePlayPause])
    }

    func test_upFromTheIcons_reachesSkip_andSelectSkips() {
        context.skipSegment = intro
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
        send(.up)
        XCTAssertEqual(state.transportFocus, .skip)
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "skip")
        XCTAssertFalse(TVPlayerInputModel.scrubberHasFocus(state))
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
    }

    func test_upFromTheIcons_withoutSkip_staysOnTheIcons() {
        send(.up)
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
    }

    func test_downFromSkip_returnsToTheIconBeneathIt_andMenuToTheScrubber() {
        context.skipSegment = intro
        send(.up)
        send(.up)
        XCTAssertEqual(press(.left), [], "Left and Right do nothing on Skip")
        XCTAssertEqual(state.transportFocus, .skip)
        send(.down)
        XCTAssertEqual(state.transportFocus, .icon(.subtitles), "The rightmost icon, which sits beneath it")
        send(.up)
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_withNoIcons_upFromTheScrubberReachesSkip_andDownReturns() {
        context = TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400, skipSegment: intro)
        send(.up)
        XCTAssertEqual(state.transportFocus, .skip)
        send(.down)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_skipEnding_withFocusOnIt_returnsFocusToTheScrubber() {
        context.skipSegment = intro
        send(.up)
        send(.up)
        context.skipSegment = nil
        tick(for: 0.1)
        XCTAssertEqual(state.transportFocus, .scrubber)
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
        send(.up)
        send(.up)
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

    /// M4 review: a swipe on the card used to pause into a scan.
    func test_nextUp_transportHidden_aSwipeMovesAlongTheCard() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertEqual(send(.swipeStep(.right)), [])
        XCTAssertNil(state.scrub)
        XCTAssertEqual(state.nextUpFocus, .close)
        send(.swipeStep(.left))
        XCTAssertEqual(state.nextUpFocus, .playNow)
    }

    /// A hold on the card acts once, on release, as on the icons.
    func test_nextUp_transportHidden_aHoldMovesAlongTheCard_withoutScanning() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertEqual(send(.arrowDown(.right)), [])
        XCTAssertEqual(tick(for: 0.6), [])
        XCTAssertNil(state.scrub, "No scan opens under the card")
        send(.arrowUp(.right))
        XCTAssertEqual(state.nextUpFocus, .close)
    }

    /// Stats give way to the tabs panel and the Next Up card (Benjamin,
    /// 2026-10-08): they shared the right half of the screen.
    func test_statsPanel_hidesWhileTheTabsPanelOrNextUpShows() {
        context.statsButtonEnabled = true
        state.isStatsOn = true
        XCTAssertTrue(TVPlayerInputModel.statsPanelShows(state, context: context))
        context.nextUpSecondsRemaining = 8
        XCTAssertFalse(TVPlayerInputModel.statsPanelShows(state, context: context))
        context.nextUpSecondsRemaining = nil
        send(.down)
        XCTAssertNotNil(state.panel)
        XCTAssertFalse(TVPlayerInputModel.statsPanelShows(state, context: context))
        XCTAssertTrue(state.isStatsOn, "The toggle itself stays on")
        context.statsButtonEnabled = false
        state.panel = nil
        XCTAssertFalse(TVPlayerInputModel.statsPanelShows(state, context: context))
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

    /// With the transport up the card is the stop above the icon row, as
    /// Skip is (Benjamin, 2026-10-07).
    func test_nextUp_transportUp_upFromTheIconsFocusesTheCard() {
        context.nextUpSecondsRemaining = 8
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
        send(.up)
        XCTAssertEqual(state.transportFocus, .nextUp)
        XCTAssertTrue(TVPlayerInputModel.nextUpHasFocus(state, context: context))
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "nextUp.playNow")
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "nextUp.close")
        XCTAssertEqual(state.chrome, .transport)
        XCTAssertEqual(send(.select), [.dismissNextUp])
    }

    func test_nextUp_transportUp_selectOnPlayNowPlaysNext() {
        context.nextUpSecondsRemaining = 8
        send(.up)
        send(.up)
        XCTAssertEqual(send(.select), [.playNext])
    }

    func test_nextUp_transportUp_downReturnsToTheRightmostIcon_andMenuToTheScrubber() {
        context.nextUpSecondsRemaining = 8
        send(.up)
        send(.up)
        send(.down)
        XCTAssertEqual(state.transportFocus, .icon(.subtitles))
        send(.up)
        XCTAssertEqual(send(.menu), [], "Menu leaves the card without closing it")
        XCTAssertEqual(state.transportFocus, .scrubber)
        XCTAssertFalse(TVPlayerInputModel.nextUpHasFocus(state, context: context))
    }

    func test_nextUp_transportUp_withNoIcons_upFromTheScrubberFocusesTheCard() {
        context = TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400, nextUpSecondsRemaining: 8)
        send(.up)
        XCTAssertEqual(state.transportFocus, .nextUp)
    }

    func test_nextUp_cardGoing_withFocusOnIt_returnsFocusToTheScrubber() {
        context.nextUpSecondsRemaining = 8
        send(.up)
        send(.up)
        context.nextUpSecondsRemaining = nil
        tick(for: 0.1)
        XCTAssertEqual(state.transportFocus, .scrubber)
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
