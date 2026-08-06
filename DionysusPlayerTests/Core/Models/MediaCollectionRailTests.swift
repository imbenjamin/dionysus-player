import XCTest
@testable import Dionysus

/// `MediaCollectionRail.usesLandscapeTiles` decides `PosterCard` vs.
/// `LandscapeMediaCard` for a whole rail at once — see that property's doc
/// comment for why it's whole-rail rather than per-item.
final class MediaCollectionRailTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    private func makeItem(_ type: BaseItemKind) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: "\(type.rawValue)-1", name: "Item", type: type), images: images)
    }

    func test_usesLandscapeTiles_falseWhenEveryItemIsMovie() {
        let rail = MediaCollectionRail(title: "Recently Added Movies", items: [makeItem(.movie), makeItem(.movie)])
        XCTAssertFalse(rail.usesLandscapeTiles)
    }

    func test_usesLandscapeTiles_trueWhenEveryItemIsSeriesOrEpisode() {
        let rail = MediaCollectionRail(title: "Recently Added Shows", items: [makeItem(.series), makeItem(.episode)])
        XCTAssertTrue(rail.usesLandscapeTiles)
    }

    /// The scenario this exists for: "Continue Watching" can genuinely mix
    /// a movie and an in-progress episode. The whole rail should read as
    /// one consistent tile shape, not a jumble of two.
    func test_usesLandscapeTiles_trueWhenMixingMoviesAndEpisodes() {
        let rail = MediaCollectionRail(title: "Continue Watching", items: [makeItem(.movie), makeItem(.episode)])
        XCTAssertTrue(rail.usesLandscapeTiles)
    }

    func test_usesLandscapeTiles_falseWhenEmpty() {
        let rail = MediaCollectionRail(title: "Empty", items: [])
        XCTAssertFalse(rail.usesLandscapeTiles)
    }
}
