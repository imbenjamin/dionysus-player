import XCTest
@testable import Dionysus

final class TVPlayerInfoArtTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jf.example")!, accessToken: nil)

    private func item(_ kind: BaseItemKind, tags: [String: String] = [:], parentThumb: String? = nil) -> MediaItem {
        var dto = BaseItemDto(id: "item", name: "Name", type: kind)
        dto.imageTags = tags
        dto.seriesId = "series"
        if let parentThumb {
            dto.parentThumbItemId = "series"
            dto.parentThumbImageTag = parentThumb
        }
        return MediaItem(dto: dto, images: images)
    }

    func test_aMovie_showsItsPoster() {
        let art = TVPlayerInfoArt(item: item(.movie, tags: ["Primary": "p"]))
        XCTAssertEqual(art.shape, .poster)
        XCTAssertTrue(art.url?.absoluteString.contains("/Items/item/Images/Primary") ?? false)
    }

    func test_anEpisode_showsItsThumb_thenItsStill_thenTheShowsThumb() {
        XCTAssertTrue(TVPlayerInfoArt(item: item(.episode, tags: ["Thumb": "t", "Primary": "p"])).url?.absoluteString.contains("Images/Thumb") ?? false)
        let still = TVPlayerInfoArt(item: item(.episode, tags: ["Primary": "p"]))
        XCTAssertEqual(still.shape, .landscape)
        XCTAssertTrue(still.url?.absoluteString.contains("/Items/item/Images/Primary") ?? false)
        let show = TVPlayerInfoArt(item: item(.episode, parentThumb: "s"))
        XCTAssertTrue(show.url?.absoluteString.contains("/Items/series/Images/Thumb") ?? false)
        XCTAssertNil(TVPlayerInfoArt(item: item(.episode)).url, "Nothing to show: the glyph stands in")
    }
}
