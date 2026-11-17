import XCTest
@testable import Dionysus

final class NightModeScheduleRulesTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func schedule(
        enabled: Bool = true,
        on: TimeOfDay = TimeOfDay(hour: 22, minute: 0),
        off: TimeOfDay = TimeOfDay(hour: 7, minute: 0)
    ) -> NightModeSchedule {
        NightModeSchedule(isEnabled: enabled, turnOn: on, turnOff: off)
    }

    func test_noBoundary_whenScheduleOff() {
        let result = NightModeScheduleRules.boundaryToApply(
            schedule: schedule(enabled: false), lastApplied: date(2026, 11, 16, 21),
            now: date(2026, 11, 16, 23), calendar: calendar)
        XCTAssertNil(result)
        XCTAssertNil(NightModeScheduleRules.nextBoundary(
            after: date(2026, 11, 16, 6), schedule: schedule(enabled: false), calendar: calendar))
    }

    func test_noBoundary_whenNeverApplied() {
        XCTAssertNil(NightModeScheduleRules.boundaryToApply(
            schedule: schedule(), lastApplied: nil,
            now: date(2026, 11, 16, 23), calendar: calendar))
    }

    func test_turnsOn_atStart() {
        let result = NightModeScheduleRules.boundaryToApply(
            schedule: schedule(), lastApplied: date(2026, 11, 16, 21),
            now: date(2026, 11, 16, 22), calendar: calendar)
        XCTAssertEqual(result?.turnsOn, true)
        XCTAssertEqual(result?.date, date(2026, 11, 16, 22))
    }

    func test_turnsOff_atEnd_acrossMidnight() {
        let result = NightModeScheduleRules.boundaryToApply(
            schedule: schedule(on: TimeOfDay(hour: 22, minute: 30)),
            lastApplied: date(2026, 11, 16, 23),
            now: date(2026, 11, 17, 7, 5), calendar: calendar)
        XCTAssertEqual(result?.turnsOn, false)
        XCTAssertEqual(result?.date, date(2026, 11, 17, 7))
    }

    func test_missedBoundaries_collapseToLatest() {
        let result = NightModeScheduleRules.boundaryToApply(
            schedule: schedule(), lastApplied: date(2026, 11, 14, 20),
            now: date(2026, 11, 16, 23), calendar: calendar)
        XCTAssertEqual(result?.turnsOn, true)
        XCTAssertEqual(result?.date, date(2026, 11, 16, 22))
    }

    func test_noBoundary_whenNothingElapsed() {
        XCTAssertNil(NightModeScheduleRules.boundaryToApply(
            schedule: schedule(), lastApplied: date(2026, 11, 16, 22),
            now: date(2026, 11, 16, 23), calendar: calendar))
    }

    func test_noBoundary_whenEqualTimes() {
        let equal = schedule(on: TimeOfDay(hour: 22, minute: 0), off: TimeOfDay(hour: 22, minute: 0))
        XCTAssertTrue(equal.neverTriggers)
        XCTAssertNil(NightModeScheduleRules.boundaryToApply(
            schedule: equal, lastApplied: date(2026, 11, 14, 20),
            now: date(2026, 11, 16, 23), calendar: calendar))
        XCTAssertNil(NightModeScheduleRules.nextBoundary(
            after: date(2026, 11, 16, 6), schedule: equal, calendar: calendar))
    }

    func test_nextBoundary_isTheNearestEither() {
        XCTAssertEqual(
            NightModeScheduleRules.nextBoundary(after: date(2026, 11, 16, 6), schedule: schedule(), calendar: calendar),
            date(2026, 11, 16, 7))
        XCTAssertEqual(
            NightModeScheduleRules.nextBoundary(after: date(2026, 11, 16, 8), schedule: schedule(), calendar: calendar),
            date(2026, 11, 16, 22))
    }

    func test_dstSpringForward_stillFires() throws {
        // 2027-03-28 is the spring change in London: 01:30 doesn't exist.
        let gap = schedule(on: TimeOfDay(hour: 1, minute: 30), off: TimeOfDay(hour: 12, minute: 0))
        let boundary = try XCTUnwrap(NightModeScheduleRules.nextBoundary(
            after: date(2027, 3, 28, 0, 10), schedule: gap, calendar: calendar))
        XCTAssertTrue(calendar.isDate(boundary, inSameDayAs: date(2027, 3, 28, 12)))
        XCTAssertLessThan(boundary, date(2027, 3, 28, 12))
    }
}
