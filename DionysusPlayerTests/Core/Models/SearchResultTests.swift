import XCTest
@testable import Dionysus

/// `SearchResult.init(hint:images:)` is where a `SearchHint`'s handful of
/// fields get turned into what `SearchView`'s results list actually shows
/// (subtitle, image URL) — pure computation, so it's tested the same way
/// `MediaItemTests` covers `MediaItem`'s own display logic.
final class SearchResultTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    func test_movieHint_subtitleIsProductionYear() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, productionYear: 2016)
        let result = SearchResult(hint: hint, images: images)
        XCTAssertEqual(result.subtitle, "2016")
    }

    func test_seriesHint_subtitleIsProductionYear() {
        let hint = SearchHint(id: "series-1", name: "The Wire", type: .series, productionYear: 2002)
        let result = SearchResult(hint: hint, images: images)
        XCTAssertEqual(result.subtitle, "2002")
    }

    func test_episodeHint_subtitleIsParentSeriesName() {
        let hint = SearchHint(id: "ep-1", name: "Old Cases", type: .episode, series: "The Wire")
        let result = SearchResult(hint: hint, images: images)
        XCTAssertEqual(result.subtitle, "The Wire")
    }

    func test_boxSetHint_hasNoSubtitle() {
        let hint = SearchHint(id: "box-1", name: "Arrival Collection", type: .boxSet, productionYear: 2016)
        let result = SearchResult(hint: hint, images: images)
        XCTAssertNil(result.subtitle)
    }

    func test_imageURL_prefersThumbOverPrimaryWhenBothPresent() {
        let hint = SearchHint(
            id: "ep-1", name: "Old Cases", type: .episode,
            primaryImageTag: "primary-tag", thumbImageTag: "thumb-tag", thumbImageItemId: "series-1"
        )
        let result = SearchResult(hint: hint, images: images)
        XCTAssertEqual(result.imageURL?.path, "/Items/series-1/Images/Thumb")
    }

    func test_imageURL_fallsBackToPrimaryWhenNoThumb() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "primary-tag")
        let result = SearchResult(hint: hint, images: images)
        XCTAssertEqual(result.imageURL?.path, "/Items/movie-1/Images/Primary")
    }

    func test_imageURL_nilWhenNoImageTagsAtAll() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie)
        let result = SearchResult(hint: hint, images: images)
        XCTAssertNil(result.imageURL)
    }
}
