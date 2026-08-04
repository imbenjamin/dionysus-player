import XCTest
@testable import Dionysus

/// `AssetDetailViewModel` was previously untested. The two things worth
/// pinning down: the movie-vs-series branch in `load()` (only series fetch
/// `Seasons`), and `resolveSeriesPlaybackItemID()`'s fallback chain
/// (in-progress/next-up episode → first episode of the first season).
@MainActor
final class AssetDetailViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(itemID: String) -> AssetDetailViewModel {
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        return AssetDetailViewModel(client: client, userID: "user-1", itemID: itemID)
    }

    // MARK: load()

    func test_load_movie_fetchesSimilarAndCollectionsButNeverSeasons() async {
        let itemDto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        let similarDto = BaseItemDto(id: "movie-2", name: "Contact", type: .movie)
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/movie-1/Similar":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [similarDto], totalRecordCount: 1))
            case "/Users/user-1/Items": // BoxSets probe inside collectionsContaining
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?") — movies shouldn't trigger a Seasons fetch")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "movie-1")
        XCTAssertEqual(viewModel.similar.map(\.id), ["movie-2"])
        XCTAssertTrue(viewModel.seasons.isEmpty)
    }

    func test_load_series_alsoFetchesSeasons() async {
        let itemDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let seasonDto = BaseItemDto(id: "season-1", name: "Season 1", type: .season)
        let viewModel = makeViewModel(itemID: "series-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Shows/series-1/Seasons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [seasonDto], totalRecordCount: 1))
            case "/Items/series-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.seasons.map(\.id), ["season-1"])
    }

    func test_load_serverError_setsFailedState() async {
        let viewModel = makeViewModel(itemID: "item-1")
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        await viewModel.load()

        guard case .failed = viewModel.loadState else { return XCTFail("Expected .failed, got \(viewModel.loadState)") }
    }

    func test_loadIfNeeded_doesNotRefetchOnceItemIsPopulated() async {
        let itemDto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        let viewModel = makeViewModel(itemID: "movie-1")
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.url?.path == "/Users/user-1/Items/movie-1" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.loadIfNeeded()
        let countAfterFirstLoad = requestCount

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, countAfterFirstLoad, "Should not re-fetch once `item` is already populated")
    }

    // MARK: resolveSeriesPlaybackItemID()

    private func loadedSeriesViewModel(nextUpItems: [BaseItemDto], episodesItems: [BaseItemDto]) async -> AssetDetailViewModel {
        let itemDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let seasonDto = BaseItemDto(id: "season-1", name: "Season 1", type: .season)
        let viewModel = makeViewModel(itemID: "series-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Shows/series-1/Seasons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [seasonDto], totalRecordCount: 1))
            case "/Items/series-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: nextUpItems, totalRecordCount: nextUpItems.count))
            case "/Shows/series-1/Episodes":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: episodesItems, totalRecordCount: episodesItems.count))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        return viewModel
    }

    func test_resolveSeriesPlaybackItemID_nonSeries_returnsNil() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Items/movie-1" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        await viewModel.load()

        let result = await viewModel.resolveSeriesPlaybackItemID()

        XCTAssertNil(result)
    }

    func test_resolveSeriesPlaybackItemID_prefersNextUpOverFirstEpisode() async {
        let nextUpEpisode = BaseItemDto(id: "ep-5", name: "Ep 5", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [nextUpEpisode], episodesItems: [])

        let result = await viewModel.resolveSeriesPlaybackItemID()

        XCTAssertEqual(result, "ep-5")
    }

    func test_resolveSeriesPlaybackItemID_fallsBackToFirstEpisodeOfFirstSeasonWhenNoNextUp() async {
        let firstEpisode = BaseItemDto(id: "ep-1", name: "Ep 1", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [], episodesItems: [firstEpisode])

        let result = await viewModel.resolveSeriesPlaybackItemID()

        XCTAssertEqual(result, "ep-1")
    }
}
