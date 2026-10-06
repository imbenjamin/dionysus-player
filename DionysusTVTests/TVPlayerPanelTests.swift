import XCTest
@testable import Dionysus

final class TVPlayerPanelTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerPanelTests.standardContext
    var now: TimeInterval = 1000

    func test_down_opensInfoOnTheTabs_andDownAgainLandsOnRestart() {
        send(.down)
        XCTAssertEqual(state.panel?.tab, .info)
        XCTAssertEqual(state.panel?.focus, .tabs)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(0))
        XCTAssertEqual(send(.select), [.seek(0), .play], "Restart")
        XCTAssertNil(state.panel)
    }

    func test_down_fromHidden_opensThePanelToo() {
        state.chrome = .hidden
        send(.down)
        XCTAssertEqual(state.panel?.tab, .info)
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_tabsFollowFocus_withoutWrapping() {
        send(.down)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .chapters)
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .subtitles)
        press(.left)
        XCTAssertEqual(state.panel?.tab, .audio)
    }

    func test_chaptersTab_isAbsentWithoutChapters() {
        context.chapterStarts = []
        XCTAssertEqual(TVPlayerInputModel.availableTabs(context), [.info, .audio, .subtitles])
        send(.down)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .audio)
    }

    func test_anIcon_opensItsTab_onTheChosenRow() {
        context.selectedSubtitleIndex = 1
        send(.up)
        press(.right)
        press(.right)
        send(.select)
        XCTAssertEqual(state.panel?.tab, .subtitles)
        XCTAssertEqual(state.panel?.focus, .content(2), "Off is row 0, so the second track is row 2")
    }

    func test_chapters_landOnTheCurrentChapter_moveSideways_andSelectJumpsAndPlays() {
        context.currentTime = 3000
        send(.up)
        send(.select)
        XCTAssertEqual(state.panel?.focus, .content(2))
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.focus, .content(3), "Stops at the last")
        XCTAssertEqual(send(.select), [.seek(4050), .play])
        XCTAssertNil(state.panel)
    }

    func test_audio_selectKeepsThePanelOpen() {
        send(.up)
        press(.right)
        send(.select)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(1))
        XCTAssertEqual(send(.select), [.selectAudio(id: 1)])
        XCTAssertNotNil(state.panel)
    }

    func test_subtitles_rowZeroIsOff() {
        send(.down)
        press(.right)
        press(.right)
        press(.right)
        send(.down)
        XCTAssertEqual(send(.select), [.selectSubtitle(id: nil)])
        send(.down)
        XCTAssertEqual(send(.select), [.selectSubtitle(id: 0)])
    }

    func test_up_fromTheFirstRow_goesToTheTabs_andUpAgainCloses() {
        send(.down)
        press(.right)
        press(.right)
        send(.down)
        send(.up)
        XCTAssertEqual(state.panel?.focus, .tabs)
        send(.up)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_menu_closesFromAnywhere() {
        send(.down)
        send(.down)
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(send(.menu), [.close], "A second Menu closes the player")
    }

    func test_panel_closesAfterTenQuietSeconds_andTheTransportFadesLater() {
        send(.down)
        tick(for: 9.8)
        XCTAssertNotNil(state.panel)
        tick(for: 0.4)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.chrome, .transport)
        tick(for: 4.2)
        XCTAssertEqual(state.chrome, .hidden)
    }

    func test_swipesAndHoldsInThePanel_neverScrubBehindIt() {
        send(.down)
        XCTAssertEqual(send(.swipeBegan), [])
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [])
        XCTAssertNil(state.scrub)
        XCTAssertEqual(TVPlayerInputModel.swipeScrubs(state, context: context), false)
    }

    func test_playPause_stillWorksWithThePanelOpen() {
        send(.down)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
        XCTAssertNotNil(state.panel)
    }

    /// Review Focus 3: a list that shrinks under the panel never leaves
    /// focus past its end, so a stale row can't pick the wrong track.
    func test_aShrinkingTrackList_clampsTheFocusedRow() {
        context.subtitleTrackIDs = [0, 1, 2]
        send(.down)
        press(.right)
        press(.right)
        press(.right)
        send(.down)
        send(.down)
        send(.down)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3))
        context.subtitleTrackIDs = [5]
        tick(for: 0.1)
        XCTAssertEqual(state.panel?.focus, .content(1))
        XCTAssertEqual(send(.select), [.selectSubtitle(id: 5)])
    }
}
