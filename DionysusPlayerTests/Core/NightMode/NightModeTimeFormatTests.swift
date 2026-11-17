import XCTest
@testable import Dionysus

/// The schedule's times as a picker's `Date` and as text, shared by the
/// player's summary and both Profile pages.
final class NightModeTimeFormatTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")

    func test_dateRoundTrip_keepsTheTime() {
        for time in [TimeOfDay(hour: 0, minute: 0), TimeOfDay(hour: 21, minute: 30), TimeOfDay(hour: 23, minute: 59), TimeOfDay(hour: 2, minute: 30)] {
            XCTAssertEqual(NightModeTimeFormat.time(from: NightModeTimeFormat.date(for: time)), time)
        }
    }

    func test_time_followsTheLocalesClock() {
        XCTAssertEqual(NightModeTimeFormat.text(TimeOfDay(hour: 7, minute: 0), locale: gb), "07:00")
        let us = NightModeTimeFormat.text(TimeOfDay(hour: 21, minute: 30), locale: us)
        XCTAssertTrue(us.contains("9:30") && us.contains("PM"), us)
    }
}
