import XCTest
@testable import Dionysus

final class DownloadedItemTests: XCTestCase {
    // MARK: estimatedTotalBytes

    /// (videoBitrate + audioBitrate) * durationSeconds / 8, using the
    /// bitrate ladder's own real numbers — 1080p High is 6 Mbps video,
    /// High preset is 192 kbps audio: for a 1-hour (3600s) item that's
    /// (6_000_000 + 192_000) * 3600 / 8 bytes.
    func test_estimatedTotalBytes_matchesBitrateTimesRuntimeMath() {
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.runtimeTicks = 3600 * 10_000_000 // 1 hour
        item.bitrate = 6_000_000
        // `requestedPreset` already defaults to `.normal` from
        // `DownloadTestHelpers.makeItem`; override to `.high` so the
        // audio-bitrate term (192 kbps) matches this test's own math above.
        item.requestedPreset = .high

        let expected = Int64((6_000_000.0 + 192_000.0) * 3600 / 8)
        XCTAssertEqual(item.estimatedTotalBytes, expected)
    }

    func test_estimatedTotalBytes_nilWithoutRuntime() {
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.runtimeTicks = nil
        item.bitrate = 3_000_000
        XCTAssertNil(item.estimatedTotalBytes)
    }

    func test_estimatedTotalBytes_nilWithoutBitrate() {
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.runtimeTicks = 3600 * 10_000_000
        item.bitrate = nil
        XCTAssertNil(item.estimatedTotalBytes)
    }

    func test_estimatedTotalBytes_nilForZeroRuntime() {
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.runtimeTicks = 0
        item.bitrate = 3_000_000
        XCTAssertNil(item.estimatedTotalBytes)
    }
}
