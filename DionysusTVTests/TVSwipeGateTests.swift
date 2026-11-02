import XCTest
@testable import Dionysus

final class TVSwipeGateTests: XCTestCase {
    private var gate = TVSwipeGate()
    private let width: CGFloat = 1920

    private func move(_ x: CGFloat, _ y: CGFloat = 0, vx: CGFloat = 1000, vy: CGFloat = 0, scrubs: Bool = true) -> [TVRemoteInput] {
        gate.changed(translation: CGPoint(x: x, y: y), velocity: CGPoint(x: vx, y: vy), width: width, scrubs: scrubs)
    }

    func test_belowTheAxisDistance_nothingHappens() {
        gate.began()
        XCTAssertEqual(move(30), [])
    }

    func test_aFastHorizontalSwipe_beginsAScrub_measuredFromWhereItCommitted() {
        gate.began()
        XCTAssertEqual(move(50), [.swipeBegan])
        XCTAssertEqual(move(50 + 192), [.swipeMoved(fraction: 0.1)])
        XCTAssertEqual(gate.ended(), [.swipeEnded])
    }

    /// A resting thumb drifts slowly; it must never pause playback.
    func test_aSlowDrift_neverBeginsAScrub() {
        gate.began()
        XCTAssertEqual(move(60, vx: 100), [])
        XCTAssertEqual(move(90, vx: 150), [])
        XCTAssertEqual(gate.ended(), [])
    }

    func test_whereNoFreeScrub_aSwipeIsOneStep() {
        gate.began()
        XCTAssertEqual(move(100, scrubs: false), [], "Under the step distance")
        XCTAssertEqual(move(120, vx: 200, scrubs: false), [], "Too slow to step")
        gate.began()
        XCTAssertEqual(move(160, vx: 800, scrubs: false), [.swipeStep(.right)])
        XCTAssertEqual(move(400, vx: 800, scrubs: false), [], "Once per swipe")
    }

    func test_aVerticalSwipe_isOneUpOrDown() {
        gate.began()
        XCTAssertEqual(move(0, 160, vx: 0, vy: 900), [.down])
        XCTAssertEqual(move(0, 400, vx: 0, vy: 900), [])
        gate.began()
        XCTAssertEqual(move(0, -160, vx: 0, vy: -900), [.up])
    }
}
