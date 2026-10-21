import XCTest
@testable import Dionysus

final class ReadAheadBufferStoreTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.ReadAheadBufferStoreTests"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 30 s to 10 min in 30 s steps (Benjamin, 2026-10-21).
    func test_options_runFromThirtySecondsToTenMinutes_inThirtySecondSteps() {
        XCTAssertEqual(ReadAheadBufferStore.options.count, 20)
        XCTAssertEqual(ReadAheadBufferStore.options.first, 30)
        XCTAssertEqual(ReadAheadBufferStore.options.last, 600)
        XCTAssertTrue(zip(ReadAheadBufferStore.options, ReadAheadBufferStore.options.dropFirst()).allSatisfy { $1 - $0 == 30 })
    }

    func test_unset_isFiveMinutes() {
        XCTAssertEqual(ReadAheadBufferStore.seconds(in: defaults), 300)
    }

    func test_storedValue_isRead() {
        defaults.set(90, forKey: readAheadBufferSecondsStorageKey)
        XCTAssertEqual(ReadAheadBufferStore.seconds(in: defaults), 90)
    }

    /// A value off the steps or out of range (an older build, a hand edit)
    /// lands on the nearest step inside the range.
    func test_storedValue_offTheSteps_isSnappedAndClamped() {
        defaults.set(100, forKey: readAheadBufferSecondsStorageKey)
        XCTAssertEqual(ReadAheadBufferStore.seconds(in: defaults), 90)
        defaults.set(5, forKey: readAheadBufferSecondsStorageKey)
        XCTAssertEqual(ReadAheadBufferStore.seconds(in: defaults), 30)
        defaults.set(5000, forKey: readAheadBufferSecondsStorageKey)
        XCTAssertEqual(ReadAheadBufferStore.seconds(in: defaults), 600)
    }

    /// The engine counts ~4 s segments; a part segment rounds up.
    func test_segments_forSeconds() {
        XCTAssertEqual(ReadAheadBufferStore.segments(forSeconds: 30), 8)
        XCTAssertEqual(ReadAheadBufferStore.segments(forSeconds: 300), 75)
        XCTAssertEqual(ReadAheadBufferStore.segments(forSeconds: 600), 150)
    }

    func test_labels() {
        XCTAssertEqual(ReadAheadBufferStore.displayName(seconds: 30), "30 sec")
        XCTAssertEqual(ReadAheadBufferStore.displayName(seconds: 300), "5 min")
        XCTAssertEqual(ReadAheadBufferStore.displayName(seconds: 330), "5 min 30 sec")
        XCTAssertEqual(ReadAheadBufferStore.accessibilityLabel(seconds: 330), "5 minutes, 30 seconds")
    }
}
