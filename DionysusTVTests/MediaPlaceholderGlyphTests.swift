import XCTest
@testable import Dionysus

/// On the Apple TV the placeholder's glyph scales with its tile (Benjamin,
/// 2026-10-05): iOS's fixed 28pt was about 7% of a 375pt poster's width,
/// too small to read from the sofa, where on an iPhone tile it's about 23%.
final class MediaPlaceholderGlyphTests: XCTestCase {
    func test_theGlyphScalesWithTheTilesShorterSide() {
        XCTAssertEqual(MediaPlaceholderBox.tvGlyphSize(for: CGSize(width: 375, height: 562)), 82.5, accuracy: 0.1, "A Home poster")
        XCTAssertEqual(MediaPlaceholderBox.tvGlyphSize(for: CGSize(width: 480, height: 270)), 59.4, accuracy: 0.1, "A landscape tile, by its height")
    }

    func test_neverSmallerThanIOSs() {
        XCTAssertEqual(MediaPlaceholderBox.tvGlyphSize(for: CGSize(width: 80, height: 80)), 28, accuracy: 0.001)
        XCTAssertEqual(MediaPlaceholderBox.tvGlyphSize(for: .zero), 28, accuracy: 0.001)
    }
}
