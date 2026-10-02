import XCTest
@testable import Dionysus

/// The root page, the top page and the two beneath the top are built
/// (Benjamin, 2026-10-01): four live pages at most, however deep the path.
final class TVPageKeepAliveTests: XCTestCase {
    func test_rootAlone() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 0), [0])
    }

    func test_upToThreePushed_everythingIsLive() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 1), [0, 1])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 2), [0, 1, 2])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 3), [0, 1, 2, 3])
    }

    func test_deeper_keepsRoot_top_andTwoBeneathIt() {
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 4), [0, 2, 3, 4])
        XCTAssertEqual(TVPageKeepAlive.liveLevels(depth: 10), [0, 8, 9, 10])
    }

    func test_neverMoreThanFourLivePages() {
        for depth in 0...50 {
            XCTAssertLessThanOrEqual(TVPageKeepAlive.liveLevels(depth: depth).count, 4)
        }
    }
}
