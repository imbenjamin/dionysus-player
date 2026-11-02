import XCTest
@testable import Dionysus

final class AudioOffsetTests: XCTestCase {
    func test_normalized_clampsToTheRange() {
        XCTAssertEqual(AudioOffset.normalized(900), 500)
        XCTAssertEqual(AudioOffset.normalized(-9999), -500)
    }

    func test_normalized_roundsToTheNearestStep() {
        XCTAssertEqual(AudioOffset.normalized(44), 40)
        XCTAssertEqual(AudioOffset.normalized(45), 50)
        XCTAssertEqual(AudioOffset.normalized(-44), -40)
        XCTAssertEqual(AudioOffset.normalized(-45), -50)
    }

    func test_seconds() {
        XCTAssertEqual(AudioOffset.seconds(40), 0.04, accuracy: 0.0001)
        XCTAssertEqual(AudioOffset.seconds(-500), -0.5, accuracy: 0.0001)
    }

    func test_format_zero() {
        XCTAssertEqual(AudioOffsetFormat.value(0), "0 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(0), "In sync")
        XCTAssertEqual(AudioOffsetFormat.spoken(0), "0 milliseconds, in sync")
    }

    func test_format_positiveIsAudioLater() {
        XCTAssertEqual(AudioOffsetFormat.value(40), "+40 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(40), "Audio later")
        XCTAssertEqual(AudioOffsetFormat.spoken(40), "40 milliseconds, audio later")
    }

    func test_format_negativeIsAudioEarlier_withATrueMinusSign() {
        XCTAssertEqual(AudioOffsetFormat.value(-30), "\u{2212}30 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(-30), "Audio earlier")
        XCTAssertEqual(AudioOffsetFormat.spoken(-30), "30 milliseconds, audio earlier")
    }
}
