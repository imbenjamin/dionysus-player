import XCTest
@testable import Dionysus

/// `SearchResult.init(hint:)` and `imageURL(images:)` are where a
/// `SearchHint`'s handful of fields get turned into what `SearchView`'s
/// results list actually shows (subtitle, image URL) — pure computation,
/// so it's tested the same way `MediaItemTests` covers `MediaItem`'s own
/// display logic.
final class SearchResultTests: XCTestCase {
    private func makeImages(accessToken: String? = "tok") -> ImageURLBuilder {
        ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: accessToken)
    }

    func test_movieHint_subtitleIsProductionYear() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, productionYear: 2016)
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "2016")
    }

    func test_seriesHint_subtitleIsProductionYear() {
        let hint = SearchHint(id: "series-1", name: "The Wire", type: .series, productionYear: 2002)
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "2002")
    }

    func test_episodeHint_subtitleIsParentSeriesName() {
        let hint = SearchHint(id: "ep-1", name: "Old Cases", type: .episode, series: "The Wire")
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "The Wire")
    }

    func test_boxSetHint_hasNoSubtitle() {
        let hint = SearchHint(id: "box-1", name: "Arrival Collection", type: .boxSet, productionYear: 2016)
        let result = SearchResult(hint: hint)
        XCTAssertNil(result.subtitle)
    }

    func test_imageReference_prefersThumbOverPrimaryWhenBothPresent() {
        let hint = SearchHint(
            id: "ep-1", name: "Old Cases", type: .episode,
            primaryImageTag: "primary-tag", thumbImageTag: "thumb-tag", thumbImageItemId: "series-1"
        )
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.imageReference, .init(itemID: "series-1", type: "Thumb", tag: "thumb-tag"))
    }

    func test_imageReference_fallsBackToPrimaryWhenNoThumb() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "primary-tag")
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.imageReference, .init(itemID: "movie-1", type: "Primary", tag: "primary-tag"))
    }

    func test_imageReference_nilWhenNoImageTagsAtAll() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie)
        let result = SearchResult(hint: hint)
        XCTAssertNil(result.imageReference)
    }

    func test_imageURL_resolvesReferenceAgainstGivenBuilder() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "primary-tag")
        let result = SearchResult(hint: hint)
        let url = result.imageURL(images: makeImages(accessToken: "tok"))
        XCTAssertEqual(url?.path, "/Items/movie-1/Images/Primary")
    }

    func test_imageURL_nilWhenNoImageReference() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie)
        let result = SearchResult(hint: hint)
        XCTAssertNil(result.imageURL(images: makeImages()))
    }

    /// The whole point of storing `imageReference` instead of a resolved
    /// `URL`: the same `SearchResult` (as persisted by `SearchHistoryStore`)
    /// must resolve to a *different* URL once the session's access token
    /// has changed, rather than carrying a stale one baked in from whenever
    /// it was first selected.
    func test_imageURL_reflectsWhicheverBuilderIsPassedNotSomethingBakedInAtConstruction() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "primary-tag")
        let result = SearchResult(hint: hint)

        let oldTokenURL = result.imageURL(images: makeImages(accessToken: "old-token"))
        let newTokenURL = result.imageURL(images: makeImages(accessToken: "new-token"))

        XCTAssertNotEqual(oldTokenURL, newTokenURL)
        XCTAssertEqual(newTokenURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "ApiKey" }?.value, "new-token")
    }
}
