import XCTest
@testable import Dionysus

final class TVBufferingSpinnerTests: XCTestCase {
    /// Loading shows at once; a rebuffer, reconnect or seek only once it has
    /// lasted half a second, so a sub-second catch or a 10s skip that lands at
    /// once doesn't flash it (Benjamin, 2026-10-21: a stall showed nothing at
    /// all; 2026-10-23: nor did a long chapter jump).
    func test_delay_byState() {
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .loading), .zero)
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .buffering), .milliseconds(500))
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .reconnecting), .milliseconds(500))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .playing))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .paused))
        XCTAssertEqual(TVTransportOverlay.spinnerDelay(for: .seeking), .milliseconds(500))
        XCTAssertNil(TVTransportOverlay.spinnerDelay(for: .idle))
    }
}
