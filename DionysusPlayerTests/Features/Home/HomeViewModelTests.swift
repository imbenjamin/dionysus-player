import XCTest
@testable import Dionysus

/// `HomeViewModel.load()` fans out to five endpoints concurrently and
/// stitches the results into a hero rail, a libraries rail, and the
/// remaining content rails, then discovers and loads dynamic rails (genres,
/// studios/networks, actors, directors — `loadDynamicRailCandidates`/
/// `loadMoreDynamicRails`) — see the "Dynamic rails" section below for that
/// half. The ViewModel doc comments call curated rail selection a
/// placeholder, so this pins down current behavior (rails are omitted when
/// empty, "Continue Watching"/"Next Up" have no `seeAllQuery`) as a
/// regression net rather than a spec to defend if that logic gets
/// redesigned.
@MainActor
final class HomeViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// `shuffle` defaults to identity (not `HomeViewModel`'s own default
    /// real shuffle) — most tests here care about deterministic rail order,
    /// and the handful that don't are unaffected by an identity "shuffle".
    private func makeViewModel(
        shuffle: @escaping ([DynamicRailCandidate]) -> [DynamicRailCandidate] = { $0 }
    ) -> HomeViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "tok",
            session: MockURLProtocol.makeSession()
        )
        return HomeViewModel(client: client, userID: "user-1", shuffle: shuffle)
    }

    /// Stubs `/Genres`, `/Studios`, and `/Persons` (every discovery call
    /// `loadDynamicRailCandidates` makes) with no results — for tests
    /// focused on the curated rails, where dynamic rail discovery running
    /// (as it always does, as part of `load()`) shouldn't add any noise to
    /// assert against.
    // `nonisolated` — this test class is `@MainActor`, and without it these
    // helpers would be too, which traps at runtime (`_swift_task_
    // checkIsolatedSwift`) the moment `MockURLProtocol.requestHandler`
    // calls one: that closure runs on CFNetwork's own background queue,
    // not the MainActor. They're all pure functions over their own
    // parameters — no MainActor-isolated state involved — so relaxing
    // isolation here is free, not a workaround.
    nonisolated private static func stubNoDynamicRailCandidates(_ request: URLRequest) throws -> (HTTPURLResponse, Data)? {
        switch request.url?.path {
        case "/Genres", "/Studios", "/Persons":
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        default:
            return nil
        }
    }

    func test_load_buildsExpectedRailsAndSkipsEmptyOnes() async {
        let moviesLibrary = BaseItemDto(id: "lib-movies", name: "Movies", type: .collectionFolder, collectionType: "movies")
        let showsLibrary = BaseItemDto(id: "lib-shows", name: "Shows", type: .collectionFolder, collectionType: "tvshows")
        let heroItem = BaseItemDto(id: "hero-1", name: "Featured", type: .movie)
        let resumeItem = BaseItemDto(id: "resume-1", name: "In Progress", type: .movie)
        let nextUpItem = BaseItemDto(id: "episode-1", name: "Next Episode", type: .episode)
        let latestMovie = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)

        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
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
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [nextUpItem], totalRecordCount: 1)
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
        XCTAssertEqual(
            titles, ["Continue Watching", "Next Up", "Recently Added Movies"],
            "Recently Added Shows should be omitted when empty"
        )

        let continueWatching = viewModel.rails[0]
        XCTAssertEqual(continueWatching.items.map(\.id), ["resume-1"])
        XCTAssertNil(continueWatching.seeAllQuery)

        let nextUp = viewModel.rails[1]
        XCTAssertEqual(nextUp.items.map(\.id), ["episode-1"])
        XCTAssertNil(nextUp.seeAllQuery)

        let recentMovies = viewModel.rails[2]
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

    // MARK: Dynamic rails

    /// Stubs the curated-rail endpoints empty so a test's `/Genres`/
    /// `/Studios`/dynamic-`/Items` stubbing is all that shapes `rails`.
    // `nonisolated` — see `stubNoDynamicRailCandidates`'s doc comment above.
    nonisolated private static func stubEmptyCuratedRails(_ request: URLRequest) throws -> (HTTPURLResponse, Data)? {
        switch request.url?.path {
        case "/Users/user-1/Views", "/Users/user-1/Items/Resume", "/Shows/NextUp":
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        case "/Users/user-1/Items/Latest":
            return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
        default:
            return nil
        }
    }

    /// `count` distinct `BaseItemDto`s, IDs prefixed for readability in
    /// assertion failures — used throughout to build fetch responses that
    /// clear (or deliberately fall short of) `minimumDynamicRailItemCount`.
    // `nonisolated` — see `stubNoDynamicRailCandidates`'s doc comment above;
    // this is the helper whose live in-handler use actually crashed.
    nonisolated private static func makeItems(_ prefix: String, count: Int) -> [BaseItemDto] {
        (1...count).map { BaseItemDto(id: "\(prefix)-\($0)", name: "\(prefix) \($0)", type: .movie) }
    }

    /// Covers all four dynamic rail categories together — genres, studios,
    /// actors, and directors — specifically because they're meant to share
    /// *one* shuffle pool rather than being ordered/randomized separately
    /// (see `loadDynamicRailCandidates`'s doc comment). The identity
    /// shuffle here preserves discovery order (movie genres, show genres,
    /// movie studios, show studios, actors, directors), which both checks
    /// the titles/counts are right and doubles as the injected-shuffle
    /// test — a real shuffle would make this ordering assertion flaky.
    func test_load_appendsAllDynamicRailTypesAfterCuratedOnesWithCorrectTitles() async {
        let viewModel = makeViewModel()
        let actionMovies = Self.makeItems("action", count: 5)
        let documentaryShows = Self.makeItems("doc", count: 5)
        let marvelMovies = Self.makeItems("marvel", count: 5)
        let hboShows = Self.makeItems("hbo", count: 5)
        let hanksItems = Self.makeItems("hanks", count: 5)
        let nolanItems = Self.makeItems("nolan", count: 5)
        var personItemQueries: [String: [String: String]] = [:]

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                let genre = query["IncludeItemTypes"] == "Movie"
                    ? BaseItemDto(id: "genre-action", name: "Action", type: .unknown)
                    : BaseItemDto(id: "genre-doc", name: "Documentary", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [genre], totalRecordCount: 1))
            case "/Studios":
                let studio = query["IncludeItemTypes"] == "Movie"
                    ? BaseItemDto(id: "studio-marvel", name: "Marvel Studios", type: .unknown)
                    : BaseItemDto(id: "studio-hbo", name: "HBO", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [studio], totalRecordCount: 1))
            case "/Persons":
                let person = query["personTypes"] == "Actor"
                    ? BaseItemDto(id: "person-hanks", name: "Tom Hanks", type: .unknown)
                    : BaseItemDto(id: "person-nolan", name: "Christopher Nolan", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [person], totalRecordCount: 1))
            case "/Users/user-1/Items":
                guard query["SortBy"] != "Random" else {
                    // The hero rail's own lookup — no candidates needed here.
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                if let person = query["Person"] { personItemQueries[person] = query }
                let items: [BaseItemDto]
                switch (query["Genres"], query["Studios"], query["Person"]) {
                case ("Action", nil, nil): items = actionMovies
                case ("Documentary", nil, nil): items = documentaryShows
                case (nil, "Marvel Studios", nil): items = marvelMovies
                case (nil, "HBO", nil): items = hboShows
                case (nil, nil, "Tom Hanks"): items = hanksItems
                case (nil, nil, "Christopher Nolan"): items = nolanItems
                default: items = []
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(
            viewModel.rails.map(\.title),
            [
                "Action Movies", "Documentary Shows", "Movies from Marvel Studios", "Shows from HBO",
                "Starring Tom Hanks", "Directed by Christopher Nolan"
            ]
        )
        XCTAssertEqual(viewModel.rails.map { $0.items.count }, [5, 5, 5, 5, 5, 5])
        XCTAssertFalse(viewModel.hasMoreDynamicRails, "Only 6 candidates existed, well under one batch")

        // Actor/director item-fetches hit a genuinely different code path
        // (`.actor`/`.director` in loadMoreDynamicRails' switch) than
        // genre/studio — worth its own check that Person/PersonTypes/
        // IncludeItemTypes all reach the request correctly.
        XCTAssertEqual(personItemQueries["Tom Hanks"]?["PersonTypes"], "Actor")
        XCTAssertEqual(personItemQueries["Tom Hanks"]?["IncludeItemTypes"], "Movie,Series")
        XCTAssertEqual(personItemQueries["Christopher Nolan"]?["PersonTypes"], "Director")
    }

    /// The threshold this whole section is about: a candidate needs at
    /// least `minimumDynamicRailItemCount` (5) items to become a rail — 4 is
    /// still "some" results, not zero, but should be dropped the same as a
    /// genuinely empty one, so a genre/studio with barely any content
    /// doesn't show up as a sparse, mostly-empty rail.
    func test_loadMoreDynamicRails_dropsCandidatesBelowTheMinimumItemCountEvenWhenNonEmpty() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let genres = [
                    BaseItemDto(id: "g-sparse", name: "SparseGenre", type: .unknown),
                    BaseItemDto(id: "g-atmin", name: "AtMinimumGenre", type: .unknown),
                    BaseItemDto(id: "g-empty", name: "EmptyGenre", type: .unknown)
                ]
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: genres, totalRecordCount: genres.count))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["SortBy"] != "Random" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let items: [BaseItemDto]
                switch query["Genres"] {
                case "SparseGenre": items = Self.makeItems("sparse", count: 4) // one short of the minimum
                case "AtMinimumGenre": items = Self.makeItems("atmin", count: 5) // exactly the minimum
                default: items = [] // EmptyGenre, or anything else
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertEqual(
            viewModel.rails.map(\.title), ["AtMinimumGenre Movies"],
            "SparseGenre (4 items) and EmptyGenre (0) should both be dropped; AtMinimumGenre (exactly 5) should still load"
        )
    }

    func test_loadMoreDynamicRails_loadsInBatchesOfTen() async {
        let viewModel = makeViewModel()
        let genreDtos = (1...15).map { BaseItemDto(id: "genre-\($0)", name: "Genre\($0)", type: .unknown) }

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                let items = query["IncludeItemTypes"] == "Movie" ? genreDtos : []
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["SortBy"] != "Random" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let name = query["Genres"] ?? "?"
                let items = Self.makeItems("item-\(name)", count: 5)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.rails.count, 10, "First batch should load with load() itself")
        XCTAssertTrue(viewModel.hasMoreDynamicRails)

        await viewModel.loadMoreDynamicRails()
        XCTAssertEqual(viewModel.rails.count, 15, "Second batch should pick up the remaining 5")
        XCTAssertFalse(viewModel.hasMoreDynamicRails)

        await viewModel.loadMoreDynamicRails()
        XCTAssertEqual(viewModel.rails.count, 15, "No candidates left — should be a no-op")
    }

    func test_loadMoreDynamicRails_skipsCandidatesThatReturnNoItemsWithoutBreakingTheRestOfTheBatch() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let genres = [
                    BaseItemDto(id: "g-empty", name: "EmptyGenre", type: .unknown),
                    BaseItemDto(id: "g-real", name: "RealGenre", type: .unknown)
                ]
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: genres, totalRecordCount: 2))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["SortBy"] != "Random" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                guard query["Genres"] != "EmptyGenre" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let items = Self.makeItems("real", count: 5)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertEqual(
            viewModel.rails.map(\.title), ["RealGenre Movies"],
            "EmptyGenre's rail should be dropped; RealGenre's should still load"
        )
    }

    func test_loadMoreDynamicRails_noOpsWhileAlreadyLoading() async {
        // 15 candidates: load() consumes the first batch of 10, leaving 5
        // pending — enough room to fire loadMoreDynamicRails a second time.
        let viewModel = makeViewModel()
        let genreDtos = (1...15).map { BaseItemDto(id: "genre-\($0)", name: "Genre\($0)", type: .unknown) }
        var dynamicItemsRequestCount = 0

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                let items = query["IncludeItemTypes"] == "Movie" ? genreDtos : []
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["SortBy"] != "Random" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                dynamicItemsRequestCount += 1
                let items = Self.makeItems("item", count: 5)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.rails.count, 10)
        dynamicItemsRequestCount = 0 // isolate the concurrent-call round below

        // The MainActor's cooperative scheduling guarantees whichever of
        // these runs first sets `isLoadingMoreDynamicRails = true`
        // synchronously (no `await` before that line) before the other
        // gets a chance to check it — so this reliably exercises the
        // re-entrancy guard rather than racing.
        async let first: Void = viewModel.loadMoreDynamicRails()
        async let second: Void = viewModel.loadMoreDynamicRails()
        _ = await (first, second)

        XCTAssertEqual(viewModel.rails.count, 15, "Only the winning call should have fetched the remaining 5")
        XCTAssertEqual(dynamicItemsRequestCount, 5, "The losing concurrent call should no-op, not fire a duplicate batch")
    }
}
