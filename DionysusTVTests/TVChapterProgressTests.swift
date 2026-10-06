import XCTest
@testable import Dionysus

/// The Chapters tab's bars (Benjamin, 2026-10-06): chapters already passed
/// are full, the current one fills to the playhead, later ones are empty.
final class TVChapterProgressTests: XCTestCase {
    private let starts: [TimeInterval] = [0, 600, 1200]

    private func progress(_ index: Int, at time: TimeInterval) -> Double {
        TVPlayerPanelView.chapterProgress(index, starts: starts, duration: 1800, currentTime: time)
    }

    func test_passedChaptersAreFull_theCurrentOneIsPartial_laterOnesAreEmpty() {
        XCTAssertEqual(progress(0, at: 900), 1)
        XCTAssertEqual(progress(1, at: 900), 0.5, accuracy: 0.001)
        XCTAssertEqual(progress(2, at: 900), 0)
    }

    func test_theLastChapterEndsAtTheDuration() {
        XCTAssertEqual(progress(2, at: 1500), 0.5, accuracy: 0.001)
    }

    func test_anIndexOutOfRange_hasNoProgress() {
        XCTAssertEqual(progress(5, at: 900), 0)
    }
}
