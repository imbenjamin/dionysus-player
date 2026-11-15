import XCTest
@testable import Dionysus

/// The stub's `/PlaybackInfo` answers as Jellyfin's `MediaInfoHelper` does:
/// every source without a `MediaSourceId`, only the matching one with it.
/// Journeys on the version choice rely on both, and on the fixtures labelling
/// as intended.
final class UITestStubPlaybackInfoTests: XCTestCase {
    private func info(_ itemID: String, sourceID: String? = nil, scenario: UITestScenario = .multipleVersions) -> [MediaSourceInfo] {
        UITestStubURLProtocol.playbackInfo(
            forPath: "/Items/\(itemID)/PlaybackInfo", mediaSourceID: sourceID, scenario: scenario
        ).mediaSources ?? []
    }

    func test_playbackInfo_filtersByMediaSourceId() {
        let movie = UITestFixtureIdentity.movieID(1)
        XCTAssertEqual(info(movie).map(\.id), ["\(movie)-4k", "\(movie)-1080p"])
        XCTAssertEqual(info(movie, sourceID: "\(movie)-1080p").map(\.id), ["\(movie)-1080p"])
        // Jellyfin compares ids case-insensitively.
        XCTAssertEqual(info(movie, sourceID: "\(movie)-1080P").map(\.id), ["\(movie)-1080p"])
        XCTAssertTrue(info(movie, sourceID: "nope").isEmpty)
    }

    func test_otherScenarios_keepOneSource() {
        let movie = UITestFixtureIdentity.movieID(1)
        XCTAssertEqual(info(movie, scenario: .standard).map(\.id), ["source-\(movie)"])
        XCTAssertEqual(info("movie-03").map(\.id), ["source-movie-03"])
        XCTAssertEqual(info("episode-s2e3").map(\.id), ["source-episode-s2e3"])
    }

    func test_fixtures_labelAsIntended() {
        func labels(_ id: String) -> [String] { MediaVersion.versions(of: info(id)).map(\.label) }
        XCTAssertEqual(labels(UITestFixtureIdentity.movieID(1)), ["4K HDR10", "1080p"])
        XCTAssertEqual(labels(UITestFixtureIdentity.movieID(2)), ["Original", "Director's Cut"])
        XCTAssertEqual(labels("episode-s1e2"), ["4K HDR10", "1080p"])
        XCTAssertEqual(labels("episode-s2e1"), ["4K HDR10", "1080p"])
        XCTAssertEqual(labels("episode-s2e2"), ["Original", "Extended Edition"])
        XCTAssertTrue(labels("episode-s2e3").isEmpty)
    }
}
