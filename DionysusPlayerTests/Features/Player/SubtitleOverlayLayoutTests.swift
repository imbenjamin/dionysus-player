import XCTest
@testable import Dionysus

final class SubtitleOverlayLayoutTests: XCTestCase {
    /// The phone's values are the ones the overlay always had.
    func test_phoneMetrics_areUnchanged() {
        let phone = SubtitleOverlayMetrics.phone
        XCTAssertEqual(phone.fontSize, 20)
        XCTAssertEqual(phone.horizontalInset, 24)
        XCTAssertEqual(phone.restingBottomInset, 28)
        XCTAssertEqual(phone.controlsGap, 8)
    }

    func test_bottomInset_clearsTheChrome_andRestsWithoutIt() {
        let tv = SubtitleOverlayMetrics.tv
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            1080 - 860 + tv.controlsGap
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: false, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: .infinity, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset, "No chrome reported, nothing to clear"
        )
    }
}
