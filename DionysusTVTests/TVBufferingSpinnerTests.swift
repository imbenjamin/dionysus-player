import XCTest
@testable import Dionysus

final class TVBufferingSpinnerTests: XCTestCase {
    /// Loading shows at once; a rebuffer or reconnect only once it has lasted
    /// half a second, so a sub-second catch doesn't flash it (Benjamin,
    /// 2026-10-21: a stall showed nothing at all).
    func test_delay_byState() {
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .loading), .zero)
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .buffering), .milliseconds(500))
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .reconnecting), .milliseconds(500))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .playing))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .paused))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .seeking), "A scrub has its own preview")
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .idle))
    }
}
