import XCTest
@testable import Dionysus

/// One shape per rail or grid, as iOS decides it (Benjamin, 2026-10-05):
/// posters when every item is movie-like, landscape thumbs when any is a show
/// or an episode, so a mix reads as one shape.
@MainActor
final class TVTileShapeTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func item(_ type: BaseItemKind) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: UUID().uuidString, name: "x", type: type), images: images)
    }

    private func result(_ kind: BaseItemKind?) throws -> SearchResult {
        var json: [String: Any] = ["id": UUID().uuidString, "name": "x"]
        if let kind { json["kind"] = kind.rawValue }
        return try JSONDecoder().decode(SearchResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_onlyMovies_arePosters() {
        XCTAssertEqual(TVTileShape(items: [item(.movie), item(.movie)]), .poster)
    }

    func test_onlyShowsOrEpisodes_areLandscape() {
        XCTAssertEqual(TVTileShape(items: [item(.series), item(.episode)]), .landscape)
    }

    func test_aMix_isLandscape() {
        XCTAssertEqual(TVTileShape(items: [item(.movie), item(.episode)]), .landscape)
    }

    /// Box sets and playlists are poster-shaped, as on iOS.
    func test_boxSets_arePosters() {
        XCTAssertEqual(TVTileShape(items: [item(.boxSet), item(.movie)]), .poster)
    }

    func test_searchResults_followTheSameRule() throws {
        XCTAssertEqual(TVTileShape(results: [try result(.movie)]), .poster)
        XCTAssertEqual(TVTileShape(results: [try result(.movie), try result(.series)]), .landscape)
    }
}
