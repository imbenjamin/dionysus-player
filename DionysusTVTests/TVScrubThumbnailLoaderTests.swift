import XCTest
@testable import Dionysus

@MainActor
final class TVScrubThumbnailLoaderTests: XCTestCase {
    /// How long a test waits to show that a late answer changed nothing: the
    /// absence of an effect can't be waited on, so this only has to be longer
    /// than the main-actor hops the answer takes to land.
    private static let absenceGrace: Duration = .milliseconds(100)

    func test_requests_areThrottled_andTheLastOneAlwaysFetches() async throws {
        var now: TimeInterval = 0
        var fetched: [Double] = []
        let loader = TVScrubThumbnailLoader(clock: { now }, fetch: { seconds in
            fetched.append(seconds)
            return nil
        })
        loader.request(10)
        now += 0.05
        loader.request(20)
        now += 0.02
        loader.request(30)
        try await waitUntil { fetched.count >= 2 }
        XCTAssertEqual(fetched, [10, 30], "The first at once, then the latest once the window passes")
    }

    /// M4 review: a fetch still in flight at `reset()` set the image after it,
    /// so the next scrub opened on the last one's frame.
    func test_aFetchLandingAfterReset_isDropped() async throws {
        let gate = FetchGate()
        let loader = TVScrubThumbnailLoader(clock: { 0 }, fetch: { seconds in await gate.wait(for: seconds) })
        loader.request(10)
        try await waitUntil { gate.isWaiting(for: 10) }
        loader.reset()
        gate.finish(10)
        try await Task.sleep(for: Self.absenceGrace)
        XCTAssertNil(loader.image)
    }

    /// While answers are slower than the throttle, each one still shows.
    func test_slowAnswers_stillShow_inOrder() async throws {
        var now: TimeInterval = 0
        let gate = FetchGate()
        let loader = TVScrubThumbnailLoader(clock: { now }, fetch: { seconds in await gate.wait(for: seconds) })
        loader.request(10)
        now += 1
        loader.request(20)
        try await waitUntil { gate.isWaiting(for: 10) && gate.isWaiting(for: 20) }
        gate.finish(10)
        try await waitUntil { loader.image != nil }
        XCTAssertNotNil(loader.image, "The older answer shows while the newer is still out")
    }

    /// An older response landing after a newer one doesn't replace it.
    func test_anOlderResponse_neverReplacesANewerOne() async throws {
        var now: TimeInterval = 0
        let gate = FetchGate()
        let loader = TVScrubThumbnailLoader(clock: { now }, fetch: { seconds in await gate.wait(for: seconds) })
        loader.request(10)
        now += 1
        loader.request(20)
        try await waitUntil { gate.isWaiting(for: 10) && gate.isWaiting(for: 20) }
        gate.finish(20)
        try await waitUntil { loader.image != nil }
        let newer = loader.image
        XCTAssertNotNil(newer)
        gate.finish(10)
        try await Task.sleep(for: Self.absenceGrace)
        XCTAssertTrue(loader.image === newer, "The frame for 20s stays")
    }
}

/// Holds each fetch until the test finishes it, handing back a distinct image.
@MainActor
private final class FetchGate {
    private var waiting: [Double: CheckedContinuation<CGImage?, Never>] = [:]

    func wait(for seconds: Double) async -> CGImage? {
        await withCheckedContinuation { waiting[seconds] = $0 }
    }

    func isWaiting(for seconds: Double) -> Bool { waiting[seconds] != nil }

    func finish(_ seconds: Double) {
        waiting.removeValue(forKey: seconds)?.resume(returning: Self.image())
    }

    private static func image() -> CGImage? {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}
