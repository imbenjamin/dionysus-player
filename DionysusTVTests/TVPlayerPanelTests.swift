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

    func test_menu_closesThePanel_thenHidesTheTransport_thenCloses() {
        send(.down)
        send(.down)
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(send(.menu), [], "A second Menu hides the transport")
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(send(.menu), [.close], "A third closes the player")
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

    private func openAudio() {
        send(.down)
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .audio)
        send(.down)
    }

    private var offsetContext: TVPlayerContext.AudioOffset {
        .init(canDecrease: true, canIncrease: true, hasTitleOffset: false, scope: .thisTitle)
    }

    /// Two columns (Benjamin, 2026-10-18): tracks on the left; scope, offset
    /// and Reset on the right, numbered on from the tracks.
    func test_columns_downStaysInTheTrackColumn_rightReachesTheOffset() {
        context.audioOffset = offsetContext
        openAudio()
        XCTAssertEqual(state.panel?.focus, .content(0))
        send(.down)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(1), "Down stops at the last track")
        press(.right)
        XCTAssertEqual(state.panel?.focus, .content(3), "Right lands on the offset row")
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 3, context), .offset)
        send(.up)
        XCTAssertEqual(state.panel?.focus, .content(2), "The scope row is above it")
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 2, context), .scope)
        send(.up)
        XCTAssertEqual(state.panel?.focus, .tabs)
    }

    func test_columns_leftFromScopeOrReset_returnsToTheChosenTrack() {
        context.selectedAudioIndex = 1
        context.audioOffset = .init(canDecrease: true, canIncrease: true, hasTitleOffset: true, scope: .thisTitle)
        openAudio()
        press(.right)
        send(.up)
        XCTAssertEqual(press(.left), [])
        XCTAssertEqual(state.panel?.focus, .content(1), "Left from the scope row")
        press(.right)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(4))
        press(.left)
        XCTAssertEqual(state.panel?.focus, .content(1), "Left from Reset")
    }

    func test_offsetRow_leftRightStep() {
        context.audioOffset = offsetContext
        openAudio()
        press(.right)
        XCTAssertEqual(press(.right), [.stepAudioOffset(1)])
        XCTAssertEqual(press(.left), [.stepAudioOffset(-1)])
        XCTAssertEqual(state.panel?.focus, .content(3), "Arrows on the offset row step, never leave it")
        XCTAssertEqual(state.panel?.tab, .audio)
    }

    func test_offsetRow_stepRefusedAtTheEnd() {
        context.audioOffset = .init(canDecrease: true, canIncrease: false, hasTitleOffset: true, scope: .thisTitle)
        openAudio()
        press(.right)
        XCTAssertEqual(press(.right), [])
    }

    func test_offsetRow_holdRepeats() {
        context.audioOffset = offsetContext
        openAudio()
        press(.right)
        send(.arrowDown(.right))
        let commands = tick(for: 1.0)
        XCTAssertGreaterThanOrEqual(commands.filter { $0 == .stepAudioOffset(1) }.count, 5, "About ten a second after the hold threshold")
        XCTAssertEqual(send(.arrowUp(.right)), [], "The release of a repeating hold adds no extra step")
    }

    /// Select switches the scope; Left is the way back to the tracks.
    func test_scopeRow_selectSwitches() {
        context.audioOffset = offsetContext
        openAudio()
        press(.right)
        send(.up)
        XCTAssertEqual(press(.right), [], "Right does nothing on the scope row")
        XCTAssertEqual(send(.select), [.setAudioOffsetScope(.allTitles)])
        context.audioOffset?.scope = .allTitles
        XCTAssertEqual(send(.select), [.setAudioOffsetScope(.thisTitle)])
    }

    func test_resetRow_whenTheTitleHasItsOwn() {
        context.audioOffset = .init(canDecrease: true, canIncrease: true, hasTitleOffset: true, scope: .thisTitle)
        openAudio()
        press(.right)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(4))
        XCTAssertEqual(send(.select), [.resetAudioOffset])
        XCTAssertNotNil(state.panel, "Reset leaves the panel open")
    }

    func test_resetRow_skippedWithNothingToReset() {
        context.audioOffset = offsetContext
        openAudio()
        press(.right)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3))
    }

    /// With All Titles there's no title offset to reset, so no Reset row.
    func test_resetRow_absentUnderAllTitles() {
        context.audioOffset = .init(canDecrease: true, canIncrease: true, hasTitleOffset: false, scope: .allTitles)
        XCTAssertEqual(TVPlayerInputModel.contentCount(.audio, context), 4)
        XCTAssertNil(TVPlayerInputModel.audioRow(at: 4, context))
        openAudio()
        press(.right)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3), "Down stops at the offset row")
    }

    /// Review Focus 5.
    func test_offsetRows_absentWhenUnavailable() {
        context.audioTrackIDs = [0]
        context.selectedAudioIndex = 0
        context.audioOffset = nil
        openAudio()
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(0))
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(state.panel?.focus, .content(0), "No column to move to")
        XCTAssertNil(TVPlayerInputModel.audioRow(at: 1, context))
    }

    func test_oneTrack_isListed_andRightReachesTheOffset() {
        context.audioTrackIDs = [0]
        context.selectedAudioIndex = 0
        context.audioOffset = offsetContext
        openAudio()
        XCTAssertEqual(state.panel?.focus, .content(0))
        press(.right)
        XCTAssertEqual(state.panel?.focus, .content(2))
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 1, context), .scope)
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 2, context), .offset)
    }

    func test_accessible_adjustableRow_steps() {
        context.accessibleTransport = true
        context.audioOffset = offsetContext
        state.panel = .init(tab: .audio, focus: .content(3), lastInputAt: now)
        XCTAssertEqual(send(.control(.adjustPanelRow(3, .right))), [.stepAudioOffset(1)])
        XCTAssertEqual(send(.control(.adjustPanelRow(3, .left))), [.stepAudioOffset(-1)])
        XCTAssertEqual(send(.control(.panelRow(2))), [.setAudioOffsetScope(.allTitles)])
    }
}
