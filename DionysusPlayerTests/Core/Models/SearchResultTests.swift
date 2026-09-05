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

    func test_episodeHint_subtitleCombinesEpisodeLabelAndSeriesName() {
        let hint = SearchHint(
            id: "ep-1", name: "Old Cases", type: .episode, series: "The Wire", indexNumber: 4, parentIndexNumber: 1
        )
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "S1:E4 \u{00B7} The Wire")
    }

    func test_episodeHint_subtitleFallsBackToSeriesNameAloneWhenNumberingMissing() {
        let hint = SearchHint(id: "ep-1", name: "Old Cases", type: .episode, series: "The Wire")
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "The Wire")
    }

    func test_episodeHint_subtitleFallsBackToEpisodeLabelAloneWhenSeriesMissing() {
        let hint = SearchHint(id: "ep-1", name: "Old Cases", type: .episode, indexNumber: 4, parentIndexNumber: 1)
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "S1:E4")
    }

    /// Jellyfin doesn't always provide both season and episode number (e.g.
    /// specials) — a half-filled label like "S1:E-" would be worse than
    /// omitting it and falling back to whatever else is available.
    func test_episodeHint_subtitleOmitsEpisodeLabelWhenOnlyOneNumberPresent() {
        let seasonOnly = SearchHint(id: "ep-1", name: "Old Cases", type: .episode, series: "The Wire", parentIndexNumber: 1)
        XCTAssertEqual(SearchResult(hint: seasonOnly).subtitle, "The Wire")

        let episodeOnly = SearchHint(id: "ep-2", name: "Old Cases", type: .episode, series: "The Wire", indexNumber: 4)
        XCTAssertEqual(SearchResult(hint: episodeOnly).subtitle, "The Wire")
    }

    func test_episodeHint_noSubtitleWhenNeitherNumberingNorSeriesPresent() {
        let hint = SearchHint(id: "ep-1", name: "Old Cases", type: .episode)
        let result = SearchResult(hint: hint)
        XCTAssertNil(result.subtitle)
    }

    func test_boxSetHint_subtitleIsCollection() {
        let hint = SearchHint(id: "box-1", name: "Arrival Collection", type: .boxSet, productionYear: 2016)
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.subtitle, "Collection")
    }

    /// `init(hint:)` keeps *both* image references rather than collapsing to
    /// one — see `SearchResult.primaryImageReference`'s doc comment on why
    /// (which one a render wants depends on where it's rendering, not just
    /// this item's own kind).
    func test_init_keepsBothPrimaryAndThumbReferencesWhenBothPresent() {
        let hint = SearchHint(
            id: "ep-1", name: "Old Cases", type: .episode,
            primaryImageTag: "primary-tag", thumbImageTag: "thumb-tag", thumbImageItemId: "series-1"
        )
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.primaryImageReference, .init(itemID: "ep-1", type: "Primary", tag: "primary-tag"))
        XCTAssertEqual(result.thumbImageReference, .init(itemID: "series-1", type: "Thumb", tag: "thumb-tag"))
    }

    func test_init_thumbReferenceNilWhenNoThumb() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "primary-tag")
        let result = SearchResult(hint: hint)
        XCTAssertEqual(result.primaryImageReference, .init(itemID: "movie-1", type: "Primary", tag: "primary-tag"))
        XCTAssertNil(result.thumbImageReference)
    }

    func test_init_bothReferencesNilWhenNoImageTagsAtAll() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie)
        let result = SearchResult(hint: hint)
        XCTAssertNil(result.primaryImageReference)
        XCTAssertNil(result.thumbImageReference)
    }

    /// `imageURL(images:)` (no `preferLandscape` override) uses each item's
    /// own natural-kind preference — episode/series favor `Thumb`, matching
    /// `isLandscapeShaped`.
    func test_imageURL_prefersThumbForEpisodeWhenBothPresent() {
        let hint = SearchHint(
            id: "ep-1", name: "Old Cases", type: .episode,
            primaryImageTag: "primary-tag", thumbImageTag: "thumb-tag", thumbImageItemId: "series-1"
        )
        let result = SearchResult(hint: hint)
        let url = result.imageURL(images: makeImages())
        XCTAssertEqual(url?.path, "/Items/series-1/Images/Thumb")
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
