import XCTest
@testable import Dionysus

/// `DynamicRailCandidate.railTitle` is pure formatting logic, cheap to pin
/// down directly — see `HomeViewModelTests` for the networking/discovery
/// side of Home's dynamic rails.
final class DynamicRailCandidateTests: XCTestCase {
    func test_railTitle_movieGenre() {
        let candidate = DynamicRailCandidate(kind: .movie, category: .genre, name: "Action")
        XCTAssertEqual(candidate.railTitle, "Action Movies")
    }

    func test_railTitle_showGenre() {
        let candidate = DynamicRailCandidate(kind: .series, category: .genre, name: "Documentary")
        XCTAssertEqual(candidate.railTitle, "Documentary Shows")
    }

    func test_railTitle_movieStudio() {
        let candidate = DynamicRailCandidate(kind: .movie, category: .studio, name: "Marvel Studios")
        XCTAssertEqual(candidate.railTitle, "Movies from Marvel Studios")
    }

    func test_railTitle_showStudio() {
        let candidate = DynamicRailCandidate(kind: .series, category: .studio, name: "HBO")
        XCTAssertEqual(candidate.railTitle, "Shows from HBO")
    }
}
