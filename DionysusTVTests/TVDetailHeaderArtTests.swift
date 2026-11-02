import XCTest
@testable import Dionysus

final class TVDetailHeaderArtTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func art(_ type: BaseItemKind, tags: [String: String] = [:], backdrops: [String] = [], parentBackdrops: [String] = []) -> TVDetailHeaderArt? {
        var dto = BaseItemDto(id: "x", name: "X", type: type)
        dto.imageTags = tags
        dto.backdropImageTags = backdrops
        if !parentBackdrops.isEmpty {
            dto.parentBackdropItemId = "p"
            dto.parentBackdropImageTags = parentBackdrops
        }
        return TVDetailHeaderArt(item: MediaItem(dto: dto, images: images))
    }

    func test_anItemWithABackdrop_hasNoHeaderArt() {
        XCTAssertNil(art(.movie, tags: ["Primary": "t"], backdrops: ["b"]))
        XCTAssertNil(art(.episode, tags: ["Primary": "t"], parentBackdrops: ["b"]), "The show's backdrop counts for its episode")
    }

    func test_aMovieWithoutABackdrop_showsItsPoster() {
        let art = art(.movie, tags: ["Primary": "t", "Thumb": "u"])
        XCTAssertEqual(art?.shape, .poster)
        XCTAssertTrue(art?.url.path.hasSuffix("/Images/Primary") ?? false)
    }

    func test_aShowWithoutABackdrop_showsItsThumb_orFailingThatItsPoster() {
        let thumb = art(.series, tags: ["Primary": "t", "Thumb": "u"])
        XCTAssertEqual(thumb?.shape, .landscape)
        XCTAssertTrue(thumb?.url.path.hasSuffix("/Images/Thumb") ?? false)
        XCTAssertEqual(art(.series, tags: ["Primary": "t"])?.shape, .poster)
    }

    /// An episode's Primary image is its still frame, 16:9.
    func test_anEpisodeWithoutABackdrop_showsItsThumb_orItsStill() {
        XCTAssertTrue(art(.episode, tags: ["Primary": "t", "Thumb": "u"])?.url.path.hasSuffix("/Images/Thumb") ?? false)
        let still = art(.episode, tags: ["Primary": "t"])
        XCTAssertEqual(still?.shape, .landscape)
        XCTAssertTrue(still?.url.path.hasSuffix("/Images/Primary") ?? false)
    }

    func test_noImagesAtAll_isNoHeaderArt() {
        XCTAssertNil(art(.movie))
        XCTAssertNil(art(.series))
    }
}
