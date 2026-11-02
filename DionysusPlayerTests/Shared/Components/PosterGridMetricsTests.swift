import CoreGraphics
import XCTest
@testable import Dionysus

/// The poster grid's columns, plain and split around an iPhone Duo's fold.
final class PosterGridMetricsTests: XCTestCase {
    func test_plainGridFillsTheWidth() {
        let metrics = PosterGridMetrics(containerWidth: 402)
        XCTAssertEqual(metrics.columnCount, 3)
        XCTAssertEqual(metrics.itemWidth, (370 - 32) / 3, accuracy: 0.001)
        XCTAssertNil(metrics.foldSplit)
        XCTAssertEqual(metrics.columns.count, 3)
    }

    func test_noFoldIsThePlainGrid() {
        let metrics = PosterGridMetrics(containerWidth: 880, idealItemWidth: 160, foldGap: nil)
        XCTAssertEqual(metrics.columnCount, PosterGridMetrics(containerWidth: 880, idealItemWidth: 160).columnCount)
        XCTAssertNil(metrics.foldSplit)
    }

    /// Book pose, as measured: an 880pt grid beside the vertical side bar,
    /// the fold at 455–495. Pages of 439pt and 369pt get two columns each,
    /// the trailing page's width, and the gutter takes the rest.
    func test_foldHeldWideFallsInTheGutter() throws {
        let gap: ClosedRange<CGFloat> = 455...495
        let metrics = PosterGridMetrics(containerWidth: 880, idealItemWidth: 160, foldGap: gap)
        let split = try XCTUnwrap(metrics.foldSplit)
        XCTAssertEqual(metrics.columnCount, 4)
        XCTAssertEqual(split.leadingColumns, 2)
        XCTAssertEqual(metrics.itemWidth, (369 - 16) / 2, accuracy: 0.001)

        // Every column's edges, from the page margin, clear the fold.
        var x = PosterGridMetrics.horizontalPadding
        for index in 0..<metrics.columnCount {
            // Touching the fold's edge is clear of it.
            let column = x...(x + metrics.itemWidth)
            XCTAssertFalse(
                column.lowerBound < gap.upperBound && column.upperBound > gap.lowerBound,
                "Column \(index) at \(column) is on the fold."
            )
            x += metrics.itemWidth + metrics.spacing(after: index)
        }
        // And the last one ends at the trailing margin.
        XCTAssertEqual(x - metrics.spacing(after: metrics.columnCount - 1), 880 - 16, accuracy: 0.001)
    }

    func test_onlyTheGutterAtTheFoldWidens() {
        let metrics = PosterGridMetrics(containerWidth: 880, idealItemWidth: 160, foldGap: 455...495)
        XCTAssertEqual(metrics.spacing(after: 0), PosterGridMetrics.spacing)
        XCTAssertGreaterThan(metrics.spacing(after: 1), 40)
        XCTAssertEqual(metrics.spacing(after: 2), PosterGridMetrics.spacing)
    }

    /// A fold too near an edge for a column on that side (one half of Split
    /// View, say) leaves the plain grid.
    func test_aPageTooNarrowForAColumnKeepsThePlainGrid() {
        XCTAssertNil(PosterGridMetrics(containerWidth: 500, idealItemWidth: 160, foldGap: 455...495).foldSplit)
    }
}
