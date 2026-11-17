import XCTest
@testable import Dionysus

/// The Apple TV's schedule times step 15 minutes with − and +, wrapping past
/// midnight; an off-grid time steps to the next or previous quarter hour.
final class NightModeTimeStepTests: XCTestCase {
    private func time(_ hour: Int, _ minute: Int) -> TimeOfDay { TimeOfDay(hour: hour, minute: minute) }

    func test_stepsFifteenMinutes() {
        XCTAssertEqual(NightModeTimeStep.step(time(22, 0), forward: true), time(22, 15))
        XCTAssertEqual(NightModeTimeStep.step(time(22, 0), forward: false), time(21, 45))
        XCTAssertEqual(NightModeTimeStep.step(time(6, 45), forward: true), time(7, 0))
    }

    func test_wrapsPastMidnight() {
        XCTAssertEqual(NightModeTimeStep.step(time(23, 45), forward: true), time(0, 0))
        XCTAssertEqual(NightModeTimeStep.step(time(0, 0), forward: false), time(23, 45))
    }

    /// Not reachable on the Apple TV today (iOS's picker sets any minute,
    /// on another device's store), but a stored 22:07 lands on the grid.
    func test_offGrid_snapsToTheNextOrPreviousQuarter() {
        XCTAssertEqual(NightModeTimeStep.step(time(22, 7), forward: true), time(22, 15))
        XCTAssertEqual(NightModeTimeStep.step(time(22, 7), forward: false), time(22, 0))
        XCTAssertEqual(NightModeTimeStep.step(time(23, 50), forward: true), time(0, 0))
        XCTAssertEqual(NightModeTimeStep.step(time(0, 5), forward: false), time(0, 0))
    }

    /// A whole day of + returns to the start: no step is lost or doubled.
    func test_aDayOfStepsComesBackRound() {
        var t = time(22, 0)
        for _ in 0..<(24 * 4) { t = NightModeTimeStep.step(t, forward: true) }
        XCTAssertEqual(t, time(22, 0))
    }
}
