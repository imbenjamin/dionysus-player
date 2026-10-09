import XCTest
@testable import Dionysus

final class TVPlaybackTimeFormatTests: XCTestCase {
    func test_underAnHour_isMinutesSeconds() { XCTAssertEqual(TVPlaybackTimeFormat.string(754), "12:34") }
    func test_overAnHour_isHoursMinutesSeconds() { XCTAssertEqual(TVPlaybackTimeFormat.string(7_325), "2:02:05") }
    func test_nonFinite_isZero() {
        XCTAssertEqual(TVPlaybackTimeFormat.string(.nan), "0:00")
        XCTAssertEqual(TVPlaybackTimeFormat.string(.infinity), "0:00")
    }
    func test_negative_isZero() { XCTAssertEqual(TVPlaybackTimeFormat.string(-3), "0:00") }

    func test_spoken() {
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(750), "12 minutes, 30 seconds")
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(0), String(localized: "0 seconds"))
        XCTAssertEqual(TVPlaybackTimeFormat.spokenPosition(750, of: 6720),
                       String(localized: "12 minutes, 30 seconds of 1 hour, 52 minutes"))
    }
}
