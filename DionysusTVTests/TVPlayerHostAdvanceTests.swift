import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerHostAdvanceTests: XCTestCase {
    /// Review Focus 4: a new item starts clean but keeps Stats.
    func test_reset_forANewItem_clearsThePanelScrubAndHiddenSkip_butKeepsStats() {
        var now: TimeInterval = 0
        let input = TVPlayerInput(clock: { now })
        var context = TVPlayerContext(
            playback: .playing, currentTime: 100, duration: 600, chapterStarts: [0, 300],
            statsButtonEnabled: true, skipSegment: .init(id: "intro", endSeconds: 120)
        )
        input.context = { context }
        input.send(.up)
        now += 0.1
        input.send(.arrowDown(.right))
        now += 0.1
        input.send(.arrowUp(.right))
        input.send(.select)
        XCTAssertTrue(input.state.isStatsOn)
        input.send(.down)
        input.send(.down)
        XCTAssertNotNil(input.state.panel)
        context.playback = .paused

        input.reset()

        XCTAssertNil(input.state.panel)
        XCTAssertNil(input.state.scrub)
        XCTAssertNil(input.state.hiddenSkipSegmentID)
        XCTAssertFalse(input.state.hasRequestedAdvance)
        XCTAssertEqual(input.state.chrome, .transport)
        XCTAssertTrue(input.state.isStatsOn)
    }
}
