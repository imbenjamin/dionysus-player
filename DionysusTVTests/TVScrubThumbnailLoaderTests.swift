import XCTest
@testable import Dionysus

@MainActor
final class TVScrubThumbnailLoaderTests: XCTestCase {
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
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fetched, [10, 30], "The first at once, then the latest once the window passes")
    }
}
