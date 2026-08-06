import XCTest
@testable import Dionysus

/// `DynamicRailCandidate.railTitle` is pure formatting logic, cheap to pin
/// down directly — see `HomeViewModelTests` for the networking/discovery
/// side of Home's dynamic rails.
final class DynamicRailCandidateTests: XCTestCase {
    func test_railTitle_movieGenre() {
        XCTAssertEqual(DynamicRailCandidate.genre(kind: .movie, name: "Action").railTitle, "Action Movies")
    }

    func test_railTitle_showGenre() {
        XCTAssertEqual(DynamicRailCandidate.genre(kind: .series, name: "Documentary").railTitle, "Documentary Shows")
    }

    func test_railTitle_movieStudio() {
        XCTAssertEqual(DynamicRailCandidate.studio(kind: .movie, name: "Marvel Studios").railTitle, "Movies from Marvel Studios")
    }

    func test_railTitle_showStudio() {
        XCTAssertEqual(DynamicRailCandidate.studio(kind: .series, name: "HBO").railTitle, "Shows from HBO")
    }

    func test_railTitle_actor() {
        XCTAssertEqual(DynamicRailCandidate.actor(name: "Tom Hanks").railTitle, "Starring Tom Hanks")
    }

    func test_railTitle_director() {
        XCTAssertEqual(DynamicRailCandidate.director(name: "Christopher Nolan").railTitle, "Directed by Christopher Nolan")
    }
}
