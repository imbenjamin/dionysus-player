import XCTest
@testable import Dionysus

final class TVPlayerScrubTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerScrubTests.standardContext
    var now: TimeInterval = 1000

    func test_pressWhilePaused_opensAScrubTenSecondsOn_withoutPlaying() {
        context.playback = .paused
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(state.scrub?.previewTime, 110)
        XCTAssertEqual(state.scrub?.resumesOnCancel, false)
    }

    func test_scrubPresses_step_andSelectSeeksThereAndPlays() {
        context.playback = .paused
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.scrub?.previewTime, 130)
        XCTAssertEqual(send(.select), [.seek(130), .play])
        XCTAssertNil(state.scrub)
    }

    func test_playPause_commitsAScrubToo() {
        context.playback = .paused
        press(.left)
        XCTAssertEqual(send(.playPause), [.seek(90), .play])
    }

    func test_menu_cancels_andStaysPausedWhenTheScrubStartedPaused() {
        context.playback = .paused
        press(.right)
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.scrub)
    }

    /// Paused, a swipe is a free scrub with the preview.
    func test_swipeWhilePaused_freeScrubs() {
        context.playback = .paused
        XCTAssertEqual(send(.swipeBegan), [])
        XCTAssertNil(state.scrub?.scan)
        XCTAssertEqual(state.scrub?.resumesOnCancel, false)
    }

    func test_aFullWidthSwipe_coversAQuarterOfTheTitle() {
        context.playback = .paused
        context.chaptersInScrubber = false
        send(.swipeBegan)
        send(.swipeMoved(fraction: 1))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 100 + 1350, accuracy: 0.001)
        send(.swipeMoved(fraction: -0.1))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 0, accuracy: 0.001, "Clamped at the start")
    }

    func test_swipe_snapsToANearbyChapter_onlyWithChaptersInScrubber() {
        // 0.8% of 5400s is 43.2s either side of a chapter start.
        context.playback = .paused
        send(.swipeBegan)
        send(.swipeMoved(fraction: (1320 - 100) / 1350))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 1350, accuracy: 0.001)
        context.chaptersInScrubber = false
        send(.swipeMoved(fraction: (1320 - 100) / 1350))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 1320, accuracy: 0.001)
    }

    /// Native-style scanning (Benjamin, 2026-10-06): a hold while playing
    /// pauses and scans at level 1, 8x; the picture stays paused and only the
    /// preview moves.
    func test_holdWhilePlaying_pausesAndScansAtLevelOne() {
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 0.3), [])
        XCTAssertEqual(tick(for: 0.2), [.pause], "Past 0.4s the press is a hold")
        XCTAssertEqual(state.scrub?.scan?.level, 1)
        context.playback = .paused
        let start = state.scrub?.previewTime ?? 0
        tick(for: 2)
        XCTAssertEqual((state.scrub?.previewTime ?? 0) - start, 16, accuracy: 1.7, "8x")
    }

    func test_releasingTheHold_keepsScanning() {
        send(.arrowDown(.right))
        tick(for: 0.6)
        context.playback = .paused
        XCTAssertEqual(send(.arrowUp(.right)), [], "The release that ends the hold changes nothing")
        XCTAssertEqual(state.scrub?.scan?.level, 1)
        let before = state.scrub?.previewTime ?? 0
        tick(for: 1)
        XCTAssertGreaterThan(state.scrub?.previewTime ?? 0, before)
    }

    func test_aSwipeWhilePlaying_entersScanning_andFurtherSwipesStep() {
        XCTAssertEqual(send(.swipeStep(.left)), [.pause])
        context.playback = .paused
        XCTAssertEqual(state.scrub?.scan?.level, -1)
        send(.swipeStep(.left))
        XCTAssertEqual(state.scrub?.scan?.level, -2)
        send(.swipeStep(.right))
        XCTAssertEqual(state.scrub?.scan?.level, -1)
    }

    /// -3/-2/-1/stopped/+1/+2/+3: the same direction speeds up, the opposite
    /// slows to a stop and then scans the other way.
    func test_pressesStepTheLevel_throughAStop_toTheOtherDirection() {
        send(.arrowDown(.right))
        tick(for: 0.5)
        context.playback = .paused
        send(.arrowUp(.right))
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.scrub?.scan?.level, 3, "Capped at 3")
        XCTAssertEqual(TVPlayerInputModel.scanRate(level: 3), 64)
        press(.left)
        press(.left)
        press(.left)
        XCTAssertEqual(state.scrub?.scan?.level, 0)
        let stopped = state.scrub?.previewTime
        tick(for: 1)
        XCTAssertEqual(state.scrub?.previewTime, stopped, "Level 0 holds the preview still")
        press(.left)
        XCTAssertEqual(state.scrub?.scan?.level, -1)
        XCTAssertEqual(TVPlayerInputModel.scanRate(level: -2), -32)
    }

    func test_aScan_selectPlaysFromThePreview_andMenuGoesBackAndResumes() {
        send(.arrowDown(.right))
        tick(for: 0.5)
        context.playback = .paused
        send(.arrowUp(.right))
        tick(for: 1)
        let preview = state.scrub?.previewTime ?? 0
        XCTAssertEqual(send(.select), [.seek(preview), .play])
        XCTAssertNil(state.scrub)

        context.playback = .playing
        send(.swipeStep(.right))
        context.playback = .paused
        tick(for: 1)
        XCTAssertEqual(send(.menu), [.play], "Menu resumes where the scan started")
        XCTAssertNil(state.scrub)
    }

    /// One more glyph per level, two at level 1 (Benjamin, 2026-10-06).
    func test_scanGlyphs_areTheLevelPlusOne() {
        XCTAssertEqual(TVScanIndicator.glyphCount(level: 1), 2)
        XCTAssertEqual(TVScanIndicator.glyphCount(level: -3), 4)
        XCTAssertEqual(TVScanIndicator.glyphCount(level: 0), 1)
    }

    func test_aScanStopsAtTheEnd() {
        context.currentTime = 5399
        send(.swipeStep(.right))
        context.playback = .paused
        tick(for: 2)
        XCTAssertEqual(state.scrub?.previewTime, 5400)
        XCTAssertEqual(state.scrub?.scan?.level, 0)
    }

    func test_aShortPress_isNeverAHold() {
        send(.arrowDown(.right))
        tick(for: 0.3)
        XCTAssertEqual(send(.arrowUp(.right)), [.seek(110)], "Still a 10s skip while playing")
        XCTAssertNil(state.scrub)
    }

    func test_holdOnAnIcon_actsAsOnePressOnRelease() {
        send(.up)
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [], "No scrub opens from an icon")
        XCTAssertNil(state.scrub)
        send(.arrowUp(.right))
        XCTAssertEqual(state.transportFocus, .icon(.audio))
    }

    /// Review Focus 1.
    func test_noDuration_noScrubOpens() {
        context.duration = 0
        XCTAssertEqual(send(.swipeStep(.right)), [])
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [])
        XCTAssertNil(state.scrub)
    }

    func test_theTransportStaysUpWhileScrubbing() {
        context.playback = .paused
        press(.right)
        context.playback = .playing   // e.g. resumed by a headphone button
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
    }
}
