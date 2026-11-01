import XCTest
@testable import Dionysus

/// `PlaybackSegment.merged(_:)`: a server with two segment providers lists
/// the same intro, recap or credits twice with slightly different ends
/// (measured on Benjamin's 12.2.0 server, 2026-11-01: 115 such pairs in 300
/// episodes), and skipping the first left the second's button up.
final class PlaybackSegmentTests: XCTestCase {
    private func segment(_ id: String, _ kind: MediaSegmentType, _ start: Double, _ end: Double) -> PlaybackSegment {
        PlaybackSegment(dto: MediaSegmentDto(
            id: id, itemId: "item-1", type: kind,
            startTicks: Int64(start * 10_000_000), endTicks: Int64(end * 10_000_000)
        ))!
    }

    func test_merged_overlappingSegmentsOfOneKind_becomeOneCoveringBoth() {
        let merged = PlaybackSegment.merged([
            segment("a", .recap, 4, 74.12),
            segment("b", .recap, 4, 76.03),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "a")
        XCTAssertEqual(merged.first?.kind, .recap)
        XCTAssertEqual(merged.first?.startSeconds, 4)
        XCTAssertEqual(merged.first?.endSeconds ?? 0, 76.03, accuracy: 0.001)
    }

    func test_merged_identicalDuplicates_becomeOne() {
        let merged = PlaybackSegment.merged([
            segment("a", .outro, 2258.38, 2315.44),
            segment("b", .outro, 2258.38, 2315.44),
        ])

        XCTAssertEqual(merged.map(\.id), ["a"])
    }

    func test_merged_unorderedInput_comesBackInStartOrder() {
        let merged = PlaybackSegment.merged([
            segment("outro", .outro, 1898.87, 1921.88),
            segment("intro-long", .intro, 311.94, 356.94),
            segment("intro-short", .intro, 311.94, 352.35),
        ])

        XCTAssertEqual(merged.map(\.kind), [.intro, .outro])
        XCTAssertEqual(merged.first?.endSeconds ?? 0, 356.94, accuracy: 0.001)
    }

    /// A recap running into the intro is two buttons, one after the other:
    /// skipping the recap should land on "Skip Intro", not past it.
    func test_merged_differentKinds_stayApart() {
        let merged = PlaybackSegment.merged([
            segment("recap", .recap, 0, 62.06),
            segment("intro", .intro, 60, 120),
        ])

        XCTAssertEqual(merged.map(\.id), ["recap", "intro"])
    }

    func test_merged_separateSegmentsOfOneKind_stayApart() {
        let merged = PlaybackSegment.merged([
            segment("early", .outro, 1898.87, 1921.88),
            segment("late", .outro, 2258.38, 2315.44),
        ])

        XCTAssertEqual(merged.map(\.id), ["early", "late"])
    }
}
