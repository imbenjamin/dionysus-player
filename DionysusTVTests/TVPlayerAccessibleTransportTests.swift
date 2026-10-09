import XCTest
@testable import Dionysus

/// The accessible transport (M5): the focus engine moves and selects, so
/// the reducer ignores raw arrows and Select and takes explicit controls.
final class TVPlayerAccessibleTransportTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context: TVPlayerContext = {
        var context = TVPlayerAccessibleTransportTests.standardContext
        context.accessibleTransport = true
        return context
    }()
    var now: TimeInterval = 1000

    func test_rawArrowsSelectAndSwipes_doNothing() {
        XCTAssertEqual(send(.select), [])
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(send(.up), [])
        XCTAssertEqual(send(.down), [])
        XCTAssertEqual(send(.swipeBegan), [])
        XCTAssertEqual(send(.swipeStep(.right)), [])
        XCTAssertNil(state.scrub)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_playPauseControl_andRemotePlayPause_toggle() {
        XCTAssertEqual(send(.control(.playPause)), [.togglePlayPause])
        XCTAssertEqual(state.flash?.kind, .pause)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
    }

    func test_skipControls_seek10s_andFlash() {
        XCTAssertEqual(send(.control(.skip(.right))), [.seek(110)])
        XCTAssertEqual(state.flash?.kind, .skipForward)
        XCTAssertEqual(send(.control(.skip(.left))), [.seek(90)])
        XCTAssertEqual(state.flash?.kind, .skipBack)
    }

    func test_openPanel_switchTab_chooseRow_menuCloses() {
        send(.control(.openPanel(.audio)))
        XCTAssertEqual(state.panel?.tab, .audio)
        XCTAssertEqual(send(.control(.panelRow(1))), [.selectAudio(id: 1)])
        XCTAssertEqual(state.panel?.tab, .audio, "A track switch keeps the panel open")
        send(.control(.openPanel(.subtitles)))
        XCTAssertEqual(state.panel?.tab, .subtitles)
        XCTAssertEqual(send(.control(.panelRow(0))), [.selectSubtitle(id: nil)])
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.chrome, .transport, "Menu closes the panel first")
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.chrome, .hidden, "…then hides the controls")
        XCTAssertEqual(send(.menu), [.close], "…then leaves")
    }

    /// The controls hide by hand only (Benjamin, 2026-10-08): Menu hides
    /// them, and a control (Select, Up or Down on the layer) shows them.
    func test_menuHidesTheControls_andShowControlsBringsThemBack() {
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.chrome, .hidden)
        tick(for: 30)
        XCTAssertEqual(state.chrome, .hidden, "Nothing brings them back by itself")
        XCTAssertEqual(send(.control(.showControls)), [])
        XCTAssertEqual(state.chrome, .transport)
    }

    /// Hidden, Left and Right still skip 10s, and the controls stay hidden
    /// (Benjamin, 2026-10-08).
    func test_skipWhileHidden_seeks_andStaysHidden() {
        send(.menu)
        XCTAssertEqual(send(.control(.skip(.right))), [.seek(110)])
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(state.flash?.kind, .skipForward, "The glyph still confirms it")
        XCTAssertEqual(send(.control(.skip(.left))), [.seek(90)])
        XCTAssertEqual(state.chrome, .hidden)
    }

    func test_hiddenWhilePaused_staysHidden_soASecondMenuLeaves() {
        context.playback = .paused
        send(.menu)
        tick(for: 5)
        XCTAssertEqual(state.chrome, .hidden, "Paused, the remote's mode keeps the transport up; here the person chose")
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_chapterRow_seeksPlaysAndCloses() {
        send(.control(.openPanel(.chapters)))
        XCTAssertEqual(send(.control(.panelRow(2))), [.seek(2700), .play])
        XCTAssertNil(state.panel)
    }

    func test_openPanel_forAMissingTab_doesNothing() {
        context.chapterStarts = []
        send(.control(.openPanel(.chapters)))
        XCTAssertNil(state.panel)
    }

    func test_control_panelRow_outOfRange_doesNothing() {
        send(.control(.openPanel(.audio)))
        context.audioTrackIDs = [0]
        XCTAssertEqual(send(.control(.panelRow(1))), [])
    }

    func test_toggleStats_onlyWithItsSetting() {
        send(.control(.toggleStats))
        XCTAssertFalse(state.isStatsOn)
        context.statsButtonEnabled = true
        send(.control(.toggleStats))
        XCTAssertTrue(state.isStatsOn)
    }

    func test_skipSegment_andNextUp() {
        XCTAssertEqual(send(.control(.skipSegment)), [], "Nothing to skip")
        context.skipSegment = .init(id: "intro", endSeconds: 120)
        XCTAssertEqual(send(.control(.skipSegment)), [.skipSegment(id: "intro")])
        context.skipSegment = nil
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [], "No card")
        context.nextUpSecondsRemaining = 8
        XCTAssertEqual(send(.control(.nextUp(.close))), [.dismissNextUp])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [.playNext])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [], "Once only")
    }

    func test_accessibleTransport_nextUpAtZero_advancesOnce() {
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [.playNext])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [])
    }

    func test_control_whileLoading_doesNothing() {
        context.playback = .loading
        XCTAssertEqual(send(.control(.playPause)), [])
        XCTAssertEqual(send(.control(.skip(.right))), [])
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_accessibleTransport_neverFades_andThePanelNeverTimesOut() {
        tick(for: TVPlayerTiming.chromeFade + 30)
        XCTAssertEqual(state.chrome, .transport)
        send(.control(.openPanel(.info)))
        tick(for: TVPlayerTiming.panelTimeout + 30)
        XCTAssertEqual(state.panel?.tab, .info)
    }

    /// Turned on mid-playback with the transport faded (Review Focus 1): it
    /// stays hidden, and the layer's Show Player Controls brings it up.
    func test_turnedOnWhileHidden_staysHidden_untilShown() {
        context.accessibleTransport = false
        tick(for: TVPlayerTiming.chromeFade + 1)
        XCTAssertEqual(state.chrome, .hidden)
        context.accessibleTransport = true
        tick(for: 1)
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(state.transportFocus, .scrubber)
        send(.control(.showControls))
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_controlsOutsideTheMode_doNothing() {
        context.accessibleTransport = false
        XCTAssertEqual(send(.control(.playPause)), [])
    }
}
