import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerInputTests: XCTestCase {
    func test_send_reducesAndHandsTheCommandsOver() {
        var now: TimeInterval = 50
        let input = TVPlayerInput(clock: { now })
        input.context = { TVPlayerContext(playback: .playing, currentTime: 20, duration: 600) }
        var performed: [TVPlayerCommand] = []
        input.perform = { performed += $0 }

        input.send(.arrowDown(.right))
        now += 0.1
        input.send(.arrowUp(.right))

        XCTAssertEqual(performed, [.seek(30)])
    }

    func test_start_timesTheFirstFadeFromNow_notFromZero() {
        var now: TimeInterval = 50
        let input = TVPlayerInput(clock: { now })
        input.context = { TVPlayerContext(playback: .playing, duration: 600) }
        input.start()
        input.stop()
        now += 1
        input.send(.tick)
        XCTAssertEqual(input.state.chrome, .transport, "One second in, the transport is still up")
    }

    func test_reset_keepsOnlyStats() {
        let input = TVPlayerInput(clock: { 0 })
        input.context = { TVPlayerContext(playback: .playing, duration: 600, statsButtonEnabled: true) }
        input.send(.up)
        input.send(.select)
        XCTAssertTrue(input.state.isStatsOn)
        input.reset()
        XCTAssertTrue(input.state.isStatsOn)
        XCTAssertEqual(input.state.transportFocus, .scrubber)
    }

    func test_accessibleTransport_announcesFlashesAndTracks_onlyInTheMode() {
        let input = TVPlayerInput(clock: { 1000 })
        var context = TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400, audioTrackIDs: [0, 1], selectedAudioIndex: 0)
        context.audioTrackTitles = ["English", "French"]
        input.context = { context }
        var spoken: [String] = []
        input.announce = { spoken.append($0) }
        input.send(.playPause)
        XCTAssertEqual(spoken, [], "Nothing is announced outside the mode")
        input.accessibleTransport = true
        input.send(.control(.playPause))
        input.send(.control(.openPanel(.audio)))
        input.send(.control(.panelRow(1)))
        XCTAssertEqual(spoken, [String(localized: "Paused"), String(localized: "Audio, French")])
    }

    func test_accessibleTransport_toggledLive_reachesTheReducer() {
        let input = TVPlayerInput(clock: { 1000 })
        input.context = { TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400) }
        input.accessibleTransport = true
        XCTAssertTrue(input.snapshot().accessibleTransport)
        input.send(.select)
        XCTAssertNil(input.state.flash, "Select is the focus engine's in the mode")
        input.accessibleTransport = false
        input.send(.select)
        XCTAssertEqual(input.state.flash?.kind, .pause)
    }
}
