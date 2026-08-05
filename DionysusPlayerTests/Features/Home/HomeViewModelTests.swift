import XCTest
@testable import Dionysus

/// `HomeViewModel.load()` fans out to four endpoints concurrently and
/// stitches the results into a hero rail, a libraries rail, and the
/// remaining content rails. The ViewModel doc comments call rail selection a
/// placeholder, so this pins down current behavior (rails are omitted when
/// empty, "Continue Watching" has no `seeAllQuery`) as a regression net
/// rather than a spec to defend if that logic gets redesigned.
@MainActor
final class HomeViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel() -> HomeViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "tok",
            session: MockURLProtocol.makeSession()
        )
        return HomeViewModel(client: client, userID: "user-1")
    }

    func test_load_buildsExpectedRailsAndSkipsEmptyOnes() async {
        let moviesLibrary = BaseItemDto(id: "lib-movies", name: "Movies", type: .collectionFolder, collectionType: "movies")
        let showsLibrary = BaseItemDto(id: "lib-shows", name: "Shows", type: .collectionFolder, collectionType: "tvshows")
        let heroItem = BaseItemDto(id: "hero-1", name: "Featured", type: .movie)
        let resumeItem = BaseItemDto(id: "resume-1", name: "In Progress", type: .movie)
        let latestMovie = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)

        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Views":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [moviesLibrary, showsLibrary], totalRecordCount: 2)
                )
            case "/Users/user-1/Items":
                // The hero rail's random-unwatched-items lookup — assert it
                // asks for exactly what the hero rail needs.
                let query = request.queryDictionary
                XCTAssertEqual(query["IncludeItemTypes"], "Movie,Series")
                XCTAssertEqual(query["SortBy"], "Random")
                XCTAssertEqual(query["Filters"], "IsUnplayed")
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [heroItem], totalRecordCount: 1)
                )
            case "/Users/user-1/Items/Resume":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [resumeItem], totalRecordCount: 1)
                )
            case "/Users/user-1/Items/Latest":
                let query = request.queryDictionary
                let items = query["ParentId"] == "lib-movies" ? [latestMovie] : [] // no latest shows
                return try MockURLProtocol.encodedJSONResponse(for: request, value: items)
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)

        XCTAssertEqual(viewModel.heroItems.map(\.id), ["hero-1"])

        XCTAssertEqual(viewModel.libraries.map(\.id), ["lib-movies", "lib-shows"])

        let titles = viewModel.rails.map(\.title)
        XCTAssertEqual(titles, ["Continue Watching", "Recently Added Movies"], "Recently Added Shows should be omitted when empty")

        let continueWatching = viewModel.rails[0]
        XCTAssertEqual(continueWatching.items.map(\.id), ["resume-1"])
        XCTAssertNil(continueWatching.seeAllQuery)

        let recentMovies = viewModel.rails[1]
        XCTAssertEqual(recentMovies.items.map(\.id), ["movie-1"])
        XCTAssertEqual(recentMovies.seeAllQuery?.parentID, "lib-movies")
    }

    func test_load_serverError_setsFailedStateAndLeavesRailsEmpty() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        await viewModel.load()

        guard case .failed = viewModel.loadState else {
            return XCTFail("Expected .failed, got \(viewModel.loadState)")
        }
        XCTAssertTrue(viewModel.heroItems.isEmpty)
        XCTAssertTrue(viewModel.libraries.isEmpty)
        XCTAssertTrue(viewModel.rails.isEmpty)
    }

    func test_loadIfNeeded_doesNothingOnceAlreadyLoaded() async {
        let viewModel = makeViewModel()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            switch request.url?.path {
            case "/Users/user-1/Items/Resume":
                let item = BaseItemDto(id: "resume-1", name: "In Progress", type: .movie)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [item], totalRecordCount: 1))
            case "/Users/user-1/Items/Latest":
                // `latestItems` decodes a bare array, not a query-result envelope.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.loadIfNeeded()
        XCTAssertEqual(viewModel.loadState, .loaded)
        let countAfterFirstLoad = requestCount

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, countAfterFirstLoad, "Should not re-fetch once already loaded")
    }

    /// Regression test for switching the `loadIfNeeded` guard from "rails
    /// empty" to "loadState == .idle": a server with no libraries, no
    /// continue-watching, and nothing recently added still fully succeeds
    /// (every array legitimately empty) — that must count as "already
    /// loaded", not look like a fresh, never-loaded state that keeps
    /// re-fetching on every reappearance.
    func test_loadIfNeeded_doesNotRefetchWhenEverythingLoadedEmpty() async {
        let viewModel = makeViewModel()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.url?.path == "/Users/user-1/Items/Latest" {
                // `latestItems` decodes a bare array, not a query-result envelope.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.loadIfNeeded()
        XCTAssertEqual(viewModel.loadState, .loaded)
        let countAfterFirstLoad = requestCount

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, countAfterFirstLoad, "Should not re-fetch just because everything loaded empty")
    }
}
