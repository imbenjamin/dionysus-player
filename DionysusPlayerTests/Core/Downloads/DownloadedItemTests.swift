import XCTest
@testable import Dionysus

final class DownloadedItemTests: XCTestCase {
    // MARK: estimatedTotalBytes

    /// (videoBitrate + audioBitrate) * durationSeconds / 8, using the
    /// bitrate ladder's own real numbers — 1080p High is 4.5 Mbps video,
    /// High preset is 160 kbps audio: for a 1-hour (3600s) item that's
    /// (4_500_000 + 160_000) * 3600 / 8 bytes.
    func test_estimatedTotalBytes_matchesBitrateTimesRuntimeMath() {
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.runtimeTicks = 3600 * 10_000_000 // 1 hour
        item.bitrate = DownloadResolution.hd1080p.videoBitrate(preset: .high)
        // `requestedPreset` already defaults to `.normal` from
        // `DownloadTestHelpers.makeItem`; override to `.high` so the
        // audio-bitrate term matches this test's own math above.
        item.requestedPreset = .high

        let expected = Int64(
            (Double(DownloadResolution.hd1080p.videoBitrate(preset: .high))
                + Double(DownloadBitratePreset.high.audioBitrate)) * 3600 / 8
        )
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
