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
    override func tearDown() async throws {
        MockURLProtocol.reset()
        // `LibraryAvailability` is a true `.shared` singleton (unlike the
        // fresh `HomeViewModel` each test constructs), so a test that lets
        // `load()`/`retryLoadIfNeeded()` write to it would otherwise leak
        // that state into whichever test runs next.
        LibraryAvailability.shared.reset()
        try await super.tearDown()
    }

    /// `shuffle`/`itemShuffle` both default to identity (not `HomeViewModel`'s
    /// own default real shuffle) — most tests here care about deterministic
    /// rail/item order, and the handful that don't are unaffected by an
    /// identity "shuffle".
    private func makeViewModel(
        shuffle: @escaping ([DynamicRailCandidate]) -> [DynamicRailCandidate] = { $0 },
        itemShuffle: @escaping @Sendable ([BaseItemDto]) -> [BaseItemDto] = { $0 },
        reconnectRetrySchedule: [Double] = HomeViewModel.defaultReconnectRetrySchedule
    ) -> HomeViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "tok",
            session: MockURLProtocol.makeSession()
        )
        return HomeViewModel(
            client: client, userID: "user-1", shuffle: shuffle, itemShuffle: itemShuffle,
            reconnectRetrySchedule: reconnectRetrySchedule
        )
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
                // AUDIO SUPPRESSION: Continue Watching is scoped server-side
                // via `excludeItemTypes` — see `JellyfinAPIClient
                // .audioItemTypeExclusions`.
                XCTAssertEqual(request.queryDictionary["ExcludeItemTypes"], "Audio,AudioBook,MusicAlbum,MusicArtist,MusicGenre")
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
        XCTAssertEqual(
            recentMovies.seeAllQuery?.initialSortField, .dateAdded,
            "Recently Added's See All should preset newest-first, not the grid's own Title default"
        )
        XCTAssertEqual(recentMovies.seeAllQuery?.initialSortOrder, .descending)
    }

    /// `/Shows/NextUp` isn't guaranteed disjoint from `/Users/{id}/Items/Resume`
    /// — an item already surfaced in Continue Watching should be filtered
    /// out of Next Up rather than shown in both rails.
    func test_load_nextUp_excludesItemsAlreadyInContinueWatching() async {
        let resumeItem = BaseItemDto(id: "episode-1", name: "In Progress Episode", type: .episode)
        let genuinelyNextItem = BaseItemDto(id: "episode-2", name: "Next Episode", type: .episode)

        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Views":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items/Resume":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [resumeItem], totalRecordCount: 1)
                )
            case "/Shows/NextUp":
                // The server itself hands back both the in-progress episode
                // and the genuinely-next one.
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [resumeItem, genuinelyNextItem], totalRecordCount: 2)
                )
            case "/Users/user-1/Items/Latest":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        let continueWatching = viewModel.rails.first { $0.title == "Continue Watching" }
        XCTAssertEqual(continueWatching?.items.map(\.id), ["episode-1"])

        let nextUp = viewModel.rails.first { $0.title == "Next Up" }
        XCTAssertEqual(
            nextUp?.items.map(\.id), ["episode-2"],
            "The item already in Continue Watching should be de-duplicated out of Next Up"
        )
    }

    /// AUDIO SUPPRESSION: `/Users/{id}/Views` has no server-side type
    /// filter, so a Music library has to be dropped client-side — see
    /// `MediaItem.isAudioLibrary`.
    func test_load_excludesMusicLibraryFromLibraries() async {
        let moviesLibrary = BaseItemDto(id: "lib-movies", name: "Movies", type: .collectionFolder, collectionType: "movies")
        let musicLibrary = BaseItemDto(id: "lib-music", name: "Music", type: .collectionFolder, collectionType: "music")

        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Views":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [moviesLibrary, musicLibrary], totalRecordCount: 2)
                )
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items/Resume":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items/Latest":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.libraries.map(\.id), ["lib-movies"], "Music library should be filtered out")
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
        XCTAssertEqual(
            LibraryAvailability.shared.state, .unavailable,
            "SearchView's landing page mirrors this to show its own offline state"
        )
        XCTAssertTrue(viewModel.heroItems.isEmpty)
        XCTAssertTrue(viewModel.libraries.isEmpty)
        XCTAssertTrue(viewModel.rails.isEmpty)
    }

    /// `SearchView`'s landing page mirrors this (via `LibraryAvailability`)
    /// to know when to switch off its own "You're Offline" placeholder.
    func test_load_success_marksLibraryAvailable() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        XCTAssertEqual(LibraryAvailability.shared.state, .loading, "Nothing has loaded yet")

        await viewModel.load()

        XCTAssertEqual(LibraryAvailability.shared.state, .available)
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
                guard query["Filters"] != "IsUnplayed" else {
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
        // 6 candidates, batch size 5: load()'s own first batch only picks up
        // 5 of them, so a second call is needed to reach the 6th (director)
        // one this test also wants to exercise.
        await viewModel.loadMoreDynamicRails()

        XCTAssertEqual(
            viewModel.rails.map(\.title),
            [
                "Action Movies", "Documentary Shows", "Movies from Marvel Studios", "Shows from HBO",
                "Starring Tom Hanks", "Directed by Christopher Nolan"
            ]
        )
        XCTAssertEqual(viewModel.rails.map { $0.items.count }, [5, 5, 5, 5, 5, 5])
        XCTAssertFalse(viewModel.hasMoreDynamicRails, "Only 6 candidates existed, one batch plus a one-item remainder")

        // Genre/studio rails get a "See All" into the Movies/Shows grid,
        // preset to the matching filter — actor/director rails don't (see
        // `DynamicRailCandidate.seeAllQuery`'s doc comment for why).
        let actionMoviesQuery = viewModel.rails[0].seeAllQuery
        XCTAssertEqual(actionMoviesQuery?.title, "Movies")
        XCTAssertEqual(actionMoviesQuery?.includeItemTypes, ["Movie"])
        XCTAssertEqual(actionMoviesQuery?.initialGenre, "Action")

        let documentaryShowsQuery = viewModel.rails[1].seeAllQuery
        XCTAssertEqual(documentaryShowsQuery?.title, "Shows")
        XCTAssertEqual(documentaryShowsQuery?.includeItemTypes, ["Series"])
        XCTAssertEqual(documentaryShowsQuery?.initialGenre, "Documentary")

        let marvelMoviesQuery = viewModel.rails[2].seeAllQuery
        XCTAssertEqual(marvelMoviesQuery?.title, "Movies")
        XCTAssertEqual(marvelMoviesQuery?.includeItemTypes, ["Movie"])
        XCTAssertEqual(marvelMoviesQuery?.initialStudio, "Marvel Studios")

        let hboShowsQuery = viewModel.rails[3].seeAllQuery
        XCTAssertEqual(hboShowsQuery?.title, "Shows")
        XCTAssertEqual(hboShowsQuery?.includeItemTypes, ["Series"])
        XCTAssertEqual(hboShowsQuery?.initialStudio, "HBO")

        XCTAssertNil(viewModel.rails[4].seeAllQuery, "Starring Tom Hanks (actor) shouldn't get a See All link")
        XCTAssertNil(viewModel.rails[5].seeAllQuery, "Directed by Christopher Nolan (director) shouldn't get one either")

        // Actor/director item-fetches hit a genuinely different code path
        // (`.actor`/`.director` in loadMoreDynamicRails' switch) than
        // genre/studio — worth its own check that Person/PersonTypes/
        // IncludeItemTypes all reach the request correctly.
        XCTAssertEqual(personItemQueries["Tom Hanks"]?["PersonTypes"], "Actor")
        XCTAssertEqual(personItemQueries["Tom Hanks"]?["IncludeItemTypes"], "Movie,Series")
        XCTAssertEqual(personItemQueries["Christopher Nolan"]?["PersonTypes"], "Director")
    }

    /// A dynamic rail's own items are shuffled client-side (`itemShuffle`),
    /// not via the server's own `SortBy=Random` — see `loadMoreDynamicRails`'s
    /// doc comment for why. Uses a reversing "shuffle" (not the identity
    /// default every other test here relies on) specifically so this test
    /// can tell the items were actually run through it, not merely returned
    /// in whatever order the (stubbed, already-alphabetical) server
    /// response used.
    func test_loadMoreDynamicRails_shufflesItemsClientSide() async {
        let viewModel = makeViewModel(itemShuffle: { Array($0.reversed()) })
        let genreItems = Self.makeItems("action", count: 5)

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let genre = BaseItemDto(id: "genre-action", name: "Action", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [genre], totalRecordCount: 1))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["Filters"] != "IsUnplayed" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                guard query["Genres"] == "Action" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: genreItems, totalRecordCount: genreItems.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(
            viewModel.rails.first { $0.title == "Action Movies" }?.items.map(\.id),
            genreItems.reversed().map(\.id)
        )
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
                guard query["Filters"] != "IsUnplayed" else {
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

    func test_loadMoreDynamicRails_loadsInBatchesOfFive() async {
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
                guard query["Filters"] != "IsUnplayed" else {
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
        XCTAssertEqual(viewModel.rails.count, 5, "First batch should load with load() itself")
        XCTAssertTrue(viewModel.hasMoreDynamicRails)

        await viewModel.loadMoreDynamicRails()
        XCTAssertEqual(viewModel.rails.count, 10, "Second batch should pick up the next 5")
        XCTAssertTrue(viewModel.hasMoreDynamicRails)

        await viewModel.loadMoreDynamicRails()
        XCTAssertEqual(viewModel.rails.count, 15, "Third batch should pick up the remaining 5")
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
                guard query["Filters"] != "IsUnplayed" else {
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

    // MARK: Dynamic rail discovery failure/recovery (2026-08-18, offline detection)

    /// Confirmed live: dynamic rail discovery landing in the brief window
    /// right after the app reconnects can have one of its six fetches fail
    /// while the rest succeed — `dynamicRailCandidatesFailed` is what lets
    /// `HomeView` tell that apart from a library that legitimately has no
    /// dynamic rails to offer, so it knows whether a later "back online"
    /// transition is worth retrying.
    func test_load_oneDynamicRailFetchFails_setsDynamicRailCandidatesFailed() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Genres":
                if request.queryDictionary["IncludeItemTypes"] == "Movie" {
                    throw URLError(.networkConnectionLost)
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertTrue(viewModel.dynamicRailCandidatesFailed)
    }

    /// `HomeView` calls this when `ConnectivityMonitor` transitions back
    /// online — should re-run discovery and pick up rails that failed to
    /// load the first time.
    func test_retryDynamicRailCandidatesIfNeeded_afterFailure_succeedsAndClearsFailedFlag() async {
        let viewModel = makeViewModel()
        nonisolated(unsafe) var genresShouldFail = true
        let actionMovies = Self.makeItems("action", count: 5)

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                if genresShouldFail { throw URLError(.networkConnectionLost) }
                let genre = BaseItemDto(id: "genre-action", name: "Action", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [genre], totalRecordCount: 1))
            case "/Studios", "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["Filters"] != "IsUnplayed" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                guard query["Genres"] == "Action" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: actionMovies, totalRecordCount: actionMovies.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertTrue(viewModel.dynamicRailCandidatesFailed)
        XCTAssertTrue(viewModel.rails.isEmpty)

        genresShouldFail = false
        await viewModel.retryDynamicRailCandidatesIfNeeded()

        XCTAssertFalse(viewModel.dynamicRailCandidatesFailed)
        XCTAssertEqual(viewModel.rails.map(\.title), ["Action Movies"])
    }

    /// A partial failure (some of the six discovery calls succeed and
    /// already turn into rails, one throws) followed by a fully-successful
    /// retry must not re-append the rails that already loaded — the retry
    /// re-runs *all six* discovery calls wholesale (no cheaper way to know
    /// just which one failed last time), so without `loadDynamicRailCandidates`
    /// filtering against `consumedDynamicRailCandidates`, the genre that
    /// already succeeded the first time gets rediscovered, requeued, and
    /// appended as a second "Action Movies" rail.
    func test_retryDynamicRailCandidatesIfNeeded_afterPartialFailure_doesNotDuplicateAlreadyLoadedRails() async {
        let viewModel = makeViewModel()
        nonisolated(unsafe) var studiosShouldFail = true
        let actionMovies = Self.makeItems("action", count: 5)

        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            let query = request.queryDictionary
            switch request.url?.path {
            case "/Genres":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                let genre = BaseItemDto(id: "genre-action", name: "Action", type: .unknown)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [genre], totalRecordCount: 1))
            case "/Studios":
                guard query["IncludeItemTypes"] == "Movie" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                if studiosShouldFail { throw URLError(.networkConnectionLost) }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Persons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                guard query["Filters"] != "IsUnplayed" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                guard query["Genres"] == "Action" else {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: actionMovies, totalRecordCount: actionMovies.count))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertTrue(viewModel.dynamicRailCandidatesFailed)
        XCTAssertEqual(
            viewModel.rails.map(\.title), ["Action Movies"],
            "The genre candidate that succeeded should already be a rail before the retry"
        )

        studiosShouldFail = false
        await viewModel.retryDynamicRailCandidatesIfNeeded()

        XCTAssertFalse(viewModel.dynamicRailCandidatesFailed)
        XCTAssertEqual(
            viewModel.rails.map(\.title), ["Action Movies"],
            "Retrying after a partial failure should not re-append a rail that already loaded successfully"
        )
    }

    /// Guards against duplicate rails: an already-successful (or
    /// legitimately-empty) attempt must not be re-fetched just because
    /// connectivity happened to flip back online again later.
    func test_retryDynamicRailCandidatesIfNeeded_noPriorFailure_doesNotRefetch() async {
        let viewModel = makeViewModel()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()
        XCTAssertFalse(viewModel.dynamicRailCandidatesFailed)
        let requestCountAfterLoad = requestCount

        await viewModel.retryDynamicRailCandidatesIfNeeded()

        XCTAssertEqual(requestCount, requestCountAfterLoad, "Nothing failed, so retry should no-op without firing new requests")
    }

    /// `HomeView` calls this on the same reconnect transition as
    /// `retryDynamicRailCandidatesIfNeeded()`, but for the primary load
    /// itself — a single request failing right as connectivity flips back
    /// on (confirmed live, 2026-08-29: Wi-Fi reassociating can report
    /// "connected" before the server is actually reachable) shouldn't leave
    /// `loadState` stuck at `.failed` when a later attempt would have
    /// succeeded.
    func test_retryLoadIfNeeded_succeedsOnRetryAfterInitialFailure() async {
        let viewModel = makeViewModel(reconnectRetrySchedule: [0, 0, 0, 0])
        nonisolated(unsafe) var viewsAttempts = 0
        MockURLProtocol.requestHandler = { request in
            // `/Users/user-1/Views` is `load()`'s first, sequentially-awaited
            // request — throwing here fails the whole attempt before any of
            // its concurrent sibling requests ever fire, so counting it
            // directly counts attempts with no race against those siblings.
            if request.url?.path == "/Users/user-1/Views" {
                viewsAttempts += 1
                if viewsAttempts < 3 { throw URLError(.networkConnectionLost) }
            }
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.retryLoadIfNeeded()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewsAttempts, 3, "Should succeed on the 3rd attempt (2 failures + 1 success)")
        XCTAssertEqual(
            LibraryAvailability.shared.state, .available,
            "The two intermediate failures must never leave LibraryAvailability stuck at .unavailable"
        )
    }

    /// The flip side: a server that's still genuinely unreachable once the
    /// injected schedule is exhausted must land back on `.failed` (so the
    /// visible "Try Again" button still works) rather than retrying forever.
    func test_retryLoadIfNeeded_scheduleExhausted_leavesFailedState() async {
        let viewModel = makeViewModel(reconnectRetrySchedule: [0, 0])
        nonisolated(unsafe) var viewsAttempts = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Views" { viewsAttempts += 1 }
            throw URLError(.networkConnectionLost)
        }

        await viewModel.retryLoadIfNeeded()

        guard case .failed = viewModel.loadState else {
            return XCTFail("Expected .failed, got \(viewModel.loadState)")
        }
        XCTAssertEqual(viewsAttempts, 3, "1 immediate attempt plus the 2 scheduled retries, matching the injected schedule")
        XCTAssertEqual(LibraryAvailability.shared.state, .unavailable)
    }

    /// Regression net for a real bug found live (2026-08-29): each attempt
    /// can cost up to `JellyfinAPIClient`'s own 20s per-request timeout
    /// against a routable-but-unresponsive server, not a quick failure —
    /// the original 4-retry default multiplied that into ~100s of an
    /// unmoving spinner before finally settling back to the offline
    /// screen, which read as "stuck forever" rather than "gave it a few
    /// tries." Pins the default down to a single retry so this can't
    /// silently regress back to a long schedule — see
    /// `defaultReconnectRetrySchedule`'s own doc comment for the math.
    func test_defaultReconnectRetrySchedule_isBoundedToOneRetry() {
        XCTAssertEqual(HomeViewModel.defaultReconnectRetrySchedule.count, 1)
    }

    /// Guards against the same "duplicate work on an already-fine state"
    /// mistake `test_retryDynamicRailCandidatesIfNeeded_noPriorFailure_doesNotRefetch`
    /// pins for the dynamic-rails retry.
    func test_retryLoadIfNeeded_alreadyLoaded_doesNotRefetch() async {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded)

        MockURLProtocol.requestHandler = { request in
            XCTFail("retryLoadIfNeeded() should no-op once already loaded, but requested \(request.url?.path ?? "?")")
            throw URLError(.unknown)
        }
        await viewModel.retryLoadIfNeeded()
    }

    /// Regression test for a real bug found live (2026-08-29): tapping
    /// Search's mirrored "Try Again" (via `LibraryAvailability.retryAction`)
    /// while `HomeView`'s own automatic reconnect hook already had a
    /// `retryLoadIfNeeded()` in flight fired a second, independent `load()`
    /// racing the first — whichever finished last could clobber the other's
    /// outcome, and the visible symptom was a "Try Again" tap that just spun
    /// forever with no result. Two concurrent callers must instead coalesce
    /// into the single in-flight attempt, matching `JellyfinAPIClient`'s own
    /// `inFlightReauth` coalescing (see `test_401_concurrentFailures_
    /// coalesceIntoASingleReauthentication`) — same `async let` technique
    /// used here to actually race the two calls against each other.
    func test_retryLoadIfNeeded_concurrentCallers_coalesceIntoOneAttempt() async {
        let viewModel = makeViewModel()
        nonisolated(unsafe) var viewsAttempts = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Views" { viewsAttempts += 1 }
            if let stubbed = try Self.stubNoDynamicRailCandidates(request) { return stubbed }
            if let stubbed = try Self.stubEmptyCuratedRails(request) { return stubbed }
            switch request.url?.path {
            case "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("Unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        async let first: Void = viewModel.retryLoadIfNeeded()
        async let second: Void = viewModel.retryLoadIfNeeded()
        _ = await (first, second)

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewsAttempts, 1, "Two concurrent callers should coalesce into a single attempt, not race two independent loads")
    }

    func test_loadMoreDynamicRails_noOpsWhileAlreadyLoading() async {
        // 10 candidates: load() consumes the first batch of 5, leaving 5
        // pending — enough room to fire loadMoreDynamicRails a second time.
        let viewModel = makeViewModel()
        let genreDtos = (1...10).map { BaseItemDto(id: "genre-\($0)", name: "Genre\($0)", type: .unknown) }
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
                guard query["Filters"] != "IsUnplayed" else {
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
        XCTAssertEqual(viewModel.rails.count, 5)
        dynamicItemsRequestCount = 0 // isolate the concurrent-call round below

        // The MainActor's cooperative scheduling guarantees whichever of
        // these runs first sets `isLoadingMoreDynamicRails = true`
        // synchronously (no `await` before that line) before the other
        // gets a chance to check it — so this reliably exercises the
        // re-entrancy guard rather than racing.
        async let first: Void = viewModel.loadMoreDynamicRails()
        async let second: Void = viewModel.loadMoreDynamicRails()
        _ = await (first, second)

        XCTAssertEqual(viewModel.rails.count, 10, "Only the winning call should have fetched the remaining 5")
        XCTAssertEqual(dynamicItemsRequestCount, 5, "The losing concurrent call should no-op, not fire a duplicate batch")
    }
}
