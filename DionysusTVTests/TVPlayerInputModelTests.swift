import XCTest
@testable import Dionysus

/// The player's remote as a table: a state, an input, and the commands and
/// state that come out.
final class TVPlayerInputModelTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerInputModelTests.standardContext
    var now: TimeInterval = 1000

    func test_select_whilePlaying_togglesPlayPause_andShowsTheTransport() {
        state.chrome = .hidden
        XCTAssertEqual(send(.select), [.togglePlayPause])
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_playPause_togglesFromAnyFocus() {
        send(.up)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
    }

    /// Review Focus 1: nothing to act on while loading or failed, except
    /// Menu, which closes.
    func test_loadingOrFailed_onlyMenuActs_andItCloses() {
        for playback in [TVPlayerContext.Playback.loading, .failed] {
            context.playback = playback
            XCTAssertEqual(send(.select), [])
            XCTAssertEqual(press(.right), [])
            XCTAssertEqual(send(.menu), [.close])
        }
    }

    /// An audio switch rebuilds the session, which reads as loading with the
    /// Audio tab still open: Menu closes the tab, not the player (M4 review).
    func test_loading_menuClosesAnOpenPanelFirst() {
        send(.down)
        XCTAssertNotNil(state.panel)
        context.playback = .loading
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_up_focusesTheFirstIcon_onlyOnceTheTransportIsUp() {
        state.chrome = .hidden
        send(.up)
        XCTAssertEqual(state.transportFocus, .scrubber, "From hidden, Up only shows the transport")
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
    }

    func test_icons_areOnlyThoseWithSomethingToDo() {
        XCTAssertEqual(context.availableIcons, [.chapters, .audio, .subtitles])
        context.audioTrackIDs = [0]
        context.chapterStarts = []
        context.statsButtonEnabled = true
        XCTAssertEqual(context.availableIcons, [.subtitles, .stats])
        context.subtitleTrackIDs = []
        XCTAssertEqual(context.availableIcons, [.stats])
    }

    func test_leftRight_moveAlongTheIcons_andStopAtTheEnds() {
        send(.up)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.audio))
        press(.right)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.subtitles), "No wrap past the last icon")
        press(.left)
        press(.left)
        press(.left)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
    }

    func test_down_fromAnIcon_returnsToTheScrubber() {
        send(.up)
        send(.down)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_selectStats_togglesThePanel() {
        context.statsButtonEnabled = true
        context.chapterStarts = []
        context.audioTrackIDs = [0]
        context.subtitleTrackIDs = []
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.stats))
        XCTAssertEqual(send(.select), [])
        XCTAssertTrue(state.isStatsOn)
        send(.select)
        XCTAssertFalse(state.isStatsOn)
    }

    func test_menu_fromAnIcon_returnsToTheScrubber_thenHides_thenCloses() {
        send(.up)
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.transportFocus, .scrubber)
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(send(.menu), [.close])
    }

    /// Back with the transport up hides it rather than waiting for the fade;
    /// with nothing up it leaves (Benjamin, 2026-10-16).
    func test_menu_withTheTransportUp_hidesIt_thenCloses() {
        XCTAssertEqual(state.chrome, .transport)
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_menu_whilePaused_hidesTheTransport_andItStaysHidden() {
        context.playback = .paused
        XCTAssertEqual(send(.menu), [])
        tick(for: 10)
        XCTAssertEqual(state.chrome, .hidden, "Hidden by hand, paused or not")
        XCTAssertEqual(send(.menu), [.close])
    }

    /// While a title plays, AVKit takes Play/Pause and pauses the player
    /// itself (Bedroom Apple TV, 2026-10-16): the pause still gets its glyph.
    func test_pauseFromOutside_flashesPause_andShowsTheTransport() {
        state.chrome = .hidden
        tick(for: 0.2)
        context.playback = .paused
        send(.tick)
        XCTAssertEqual(state.flash?.kind, .pause)
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_ownPause_flashesOnce() {
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
        let serial = state.flash?.serial
        context.playback = .paused
        tick(for: 0.3)
        XCTAssertEqual(state.flash?.serial, serial, "No second flash when the pause lands")
        XCTAssertEqual(state.flash?.kind, .pause)
    }

    func test_scanPause_doesntFlash() {
        send(.swipeStep(.right))
        context.playback = .paused
        tick(for: 0.3)
        XCTAssertNil(state.flash)
    }

    func test_pressWhilePlaying_skipsTenSeconds_clampedToTheTitle() {
        XCTAssertEqual(press(.right), [.seek(110)])
        context.currentTime = 4
        XCTAssertEqual(press(.left), [.seek(0)])
        context.currentTime = 5395
        XCTAssertEqual(press(.right), [.seek(5400)])
    }

    /// Review Focus 1: with no duration yet a press seeks nowhere.
    func test_press_withNoDuration_seeksNothing() {
        context.duration = 0
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(state.chrome, .transport, "…but still shows the transport")
    }

    func test_transport_fadesFourSecondsAfterTheLastPress_andFocusReturnsToTheScrubber() {
        send(.up)
        tick(for: 3.8)
        XCTAssertEqual(state.chrome, .transport)
        tick(for: 0.4)
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_transport_neverFadesWhilePausedOrLoading_andItsFadeStartsWithPlayback() {
        state.chrome = .hidden
        tick(for: 0.1)
        context.playback = .paused
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport, "Pausing shows the transport, and it stays")
        context.playback = .loading
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
        context.playback = .playing
        tick(for: 3.8)
        XCTAssertEqual(state.chrome, .transport, "The fade is timed from playback starting")
        tick(for: 0.4)
        XCTAssertEqual(state.chrome, .hidden)
    }

    func test_autoHideDisabled_keepsTheTransportUp() {
        context.autoHideDisabled = true
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_endedPlayback_closesWhenNothingFollows_once() {
        context.playback = .ended
        XCTAssertEqual(tick(for: 1), [.close])
        context.closesWhenPlaybackEnds = false
        state.hasRequestedClose = false
        XCTAssertEqual(tick(for: 1), [], "Next Up takes over instead")
    }

    /// Review Focus 5.
    func test_focusedIconThatDisappears_fallsBackToTheScrubber() {
        send(.up)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.audio))
        context.audioTrackIDs = [0]
        tick(for: 0.1)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }
}
