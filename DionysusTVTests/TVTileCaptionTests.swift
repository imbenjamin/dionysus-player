import XCTest
@testable import Dionysus

/// A focused card lifts its artwork about 10% (measured on the Simulator: a
/// 375pt poster's bottom edge drops 19pt), so the caption beneath moves down
/// by half the growth to stay clear of it, as the prototype's 18pt does.
final class TVTileCaptionTests: XCTestCase {
    func test_captionLift_isHalfTheCardsGrowth() {
        XCTAssertEqual(TVTileMetrics.captionLift(for: TVTileMetrics.poster), 18.75, accuracy: 0.01)
        XCTAssertEqual(TVTileMetrics.captionLift(for: TVTileMetrics.landscape), 10.4, accuracy: 0.01)
    }
}
