import CoreGraphics
import XCTest
@testable import Dionysus

/// Where `FoldGapHStack` puts each view, against the fold measured on the
/// iPhone Duo held wide (x 455–495), less the grid's 16pt page margin.
final class FoldGapHStackTests: XCTestCase {
    private let gap: ClosedRange<CGFloat> = 439...479

    func test_noGapLaysOutLikeAnHStack() {
        XCTAssertEqual(FoldGapHStack.offsets(widths: [100, 50, 80], spacing: 8, gap: nil), [0, 108, 166])
    }

    func test_viewsClearOfTheGapKeepTheirPlaces() {
        XCTAssertEqual(FoldGapHStack.offsets(widths: [100, 100], spacing: 8, gap: gap), [0, 108])
    }

    /// The third view would run 416–516 across the gap, so it starts past it
    /// and the one after follows.
    func test_aViewThatWouldCrossTheGapStartsPastIt() {
        XCTAssertEqual(FoldGapHStack.offsets(widths: [200, 200, 100, 50], spacing: 8, gap: gap), [0, 208, 479, 587])
    }

    /// One that would start inside the gap (at 445) moves too.
    func test_aViewStartingInsideTheGapStartsPastIt() {
        XCTAssertEqual(FoldGapHStack.offsets(widths: [400, 50], spacing: 45, gap: gap), [0, 479])
    }

    /// The pills' group keeps the gap among its own pills, so the outer row
    /// leaves it where it is and only moves Reset.
    func test_aViewThatAppliedTheGapItselfIsNeverMoved() {
        XCTAssertEqual(
            FoldGapHStack.offsets(widths: [600, 44], movable: [false, true], spacing: 8, gap: gap),
            [0, 608]
        )
        XCTAssertEqual(
            FoldGapHStack.offsets(widths: [430, 44], movable: [false, true], spacing: 8, gap: gap),
            [0, 479]
        )
    }
}
