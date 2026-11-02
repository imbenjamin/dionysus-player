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

    /// Edges (M5 review): nothing known, a whole hour, past a day.
    func test_spoken_edges() {
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(.nan), String(localized: "0 seconds"))
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(-5), String(localized: "0 seconds"))
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(59.9), "59 seconds")
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(3600), "1 hour")
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(90_061), "25 hours, 1 minute, 1 second")
    }

    /// iOS's lead-ins: read as clocks, the times were "0 01" (M5).
    func test_spokenElapsedAndRemaining_leadInAsIOS() {
        XCTAssertEqual(TVPlaybackTimeFormat.spokenElapsed(750), String(localized: "Current position: \("12 minutes, 30 seconds")"))
        XCTAssertEqual(TVPlaybackTimeFormat.spokenRemaining(60), String(localized: "Remaining time: \("1 minute")"))
    }
}
