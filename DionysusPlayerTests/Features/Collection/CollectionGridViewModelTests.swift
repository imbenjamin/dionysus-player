import XCTest
@testable import Dionysus

@MainActor
final class CollectionGridViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(query: CollectionQuery) -> CollectionGridViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        return CollectionGridViewModel(client: client, userID: "user-1", query: query)
    }

    func test_load_passesQueryParametersThroughAndMapsItems() async {
        let query = CollectionQuery(title: "Movies", parentID: "lib-movies", includeItemTypes: ["Movie"])
        let viewModel = makeViewModel(query: query)
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.items.map(\.id), ["movie-1"])
        XCTAssertEqual(captured["ParentId"], "lib-movies")
        XCTAssertEqual(captured["IncludeItemTypes"], "Movie")
    }

    func test_load_defaultsToTitleAscendingSort() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Collections", includeItemTypes: ["BoxSet"]))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.sortField, .title)
        XCTAssertEqual(viewModel.sortOrder, .ascending)
        XCTAssertEqual(captured["SortBy"], "SortName")
        XCTAssertEqual(captured["SortOrder"], "Ascending")
        XCTAssertNil(captured["ParentId"])
    }

    // MARK: setSortField

    func test_setSortField_changesFieldAndReloads() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.dateAdded)

        XCTAssertEqual(viewModel.sortField, .dateAdded)
        XCTAssertEqual(captured["SortBy"], "DateCreated")
    }

    func test_setSortField_releaseDate() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.releaseDate)

        XCTAssertEqual(captured["SortBy"], "PremiereDate")
    }

    func test_setSortField_reselectingCurrentField_doesNotRefetch() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()
        XCTAssertEqual(requestCount, 1)

        await viewModel.setSortField(.title)
        XCTAssertEqual(requestCount, 1, "Already the current field (and the default) — shouldn't refetch")
    }

    // MARK: setSortOrder

    /// The actual point of this round of work: direction is independent of
    /// field, so a non-Title field can be flipped to ascending too (not
    /// locked to descending the way an earlier version of this had it).
    func test_setSortOrder_flipsDirectionIndependentlyOfField() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.dateAdded)
        await viewModel.setSortOrder(.ascending)

        XCTAssertEqual(viewModel.sortField, .dateAdded)
        XCTAssertEqual(viewModel.sortOrder, .ascending)
        XCTAssertEqual(captured["SortBy"], "DateCreated")
        XCTAssertEqual(captured["SortOrder"], "Ascending")
    }

    func test_setSortOrder_descendingForTitle() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortOrder(.descending)

        XCTAssertEqual(viewModel.sortField, .title, "Setting order alone shouldn't change the field")
        XCTAssertEqual(captured["SortBy"], "SortName")
        XCTAssertEqual(captured["SortOrder"], "Descending")
    }

    func test_setSortOrder_reselectingCurrentOrder_doesNotRefetch() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()
        XCTAssertEqual(requestCount, 1)

        await viewModel.setSortOrder(.ascending)
        XCTAssertEqual(requestCount, 1, "Already the current order (and the default) — shouldn't refetch")
    }

    func test_load_serverError_setsFailedState() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        await viewModel.load()

        guard case .failed = viewModel.loadState else { return XCTFail("Expected .failed, got \(viewModel.loadState)") }
    }

    func test_loadIfNeeded_doesNotRefetchOnceItemsArePopulated() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, 1, "Should not re-fetch once items are already populated")
    }

    // MARK: filtering

    /// Three movies with deliberately overlapping/non-overlapping genres,
    /// studios, and decades, so filter combinations actually distinguish
    /// them from one another.
    /// `movie-1` is watched, `movie-2` is favorited — chosen so watch-status
    /// and favorites each split the set differently than genre/studio/decade
    /// do, exercising them independently.
    private func makeFilterableMovies() -> [BaseItemDto] {
        [
            BaseItemDto(
                id: "movie-1", name: "Arrival", type: .movie, productionYear: 2016,
                genres: ["Sci-Fi", "Drama"], studios: [NameGuidPair(name: "Paramount", id: "s1")],
                userData: UserItemDataDto(played: true, isFavorite: false)
            ),
            BaseItemDto(
                id: "movie-2", name: "The Matrix", type: .movie, productionYear: 1999,
                genres: ["Sci-Fi", "Action"], studios: [NameGuidPair(name: "Warner Bros.", id: "s2")],
                userData: UserItemDataDto(played: false, isFavorite: true)
            ),
            BaseItemDto(
                id: "movie-3", name: "Inception", type: .movie, productionYear: 2010,
                genres: ["Sci-Fi", "Action"], studios: [NameGuidPair(name: "Warner Bros.", id: "s2")],
                userData: UserItemDataDto(played: false, isFavorite: false)
            ),
        ]
    }

    private func makeLoadedViewModel() async -> CollectionGridViewModel {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        let dtos = makeFilterableMovies()
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: dtos, totalRecordCount: dtos.count))
        }
        await viewModel.load()
        return viewModel
    }

    func test_availableGenres_distinctAndAlphabetical() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.availableGenres, ["Action", "Drama", "Sci-Fi"])
    }

    func test_availableStudios_distinctAndAlphabetical() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.availableStudios, ["Paramount", "Warner Bros."])
    }

    func test_availableDecades_distinctAndNewestFirst() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.availableDecades, [2010, 1990])
    }

    func test_filteredItems_noFiltersSelected_returnsEverything() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-2", "movie-3"])
    }

    func test_filteredItems_byGenre() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1"])
    }

    func test_filteredItems_byStudio() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setStudioFilter("Warner Bros.")
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-2", "movie-3"])
    }

    func test_filteredItems_byDecade() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setDecadeFilter(2010)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-3"])
    }

    // MARK: cascading facets — the actual point of this round of work

    /// Selecting Drama (only `movie-1`, a Paramount film) should narrow the
    /// *other* facets' option lists down to only what's still reachable —
    /// this is the "funnel" behavior: Warner Bros. and the 1990s decade
    /// disappear as options entirely, rather than remaining pickable and
    /// leading to a dead-end empty result.
    func test_availableStudios_narrowsToWhatCoOccursWithSelectedGenre() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableStudios, ["Paramount"])
    }

    func test_availableDecades_narrowsToWhatCoOccursWithSelectedGenre() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableDecades, [2010])
    }

    func test_availableGenres_narrowsToWhatCoOccursWithSelectedStudio() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setStudioFilter("Warner Bros.")
        // Drama drops out — no Warner Bros. film in this set is Drama.
        XCTAssertEqual(viewModel.availableGenres, ["Action", "Sci-Fi"])
    }

    func test_availableGenres_narrowsToWhatCoOccursWithSelectedDecade() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setDecadeFilter(1990)
        XCTAssertEqual(viewModel.availableGenres, ["Action", "Sci-Fi"], "Only The Matrix is 1990s, and it isn't Drama")
    }

    /// A facet's own selection shouldn't narrow its *own* option list —
    /// only the *other* two feed into it — otherwise selecting Drama would
    /// collapse the Genre list down to just ["Drama"] itself, which isn't
    /// a funnel, just a dead end.
    func test_availableGenres_notNarrowedByItsOwnSelection() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableGenres, ["Action", "Drama", "Sci-Fi"])
    }

    func test_availableOptions_narrowFurtherWithMultipleActiveFacets() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Sci-Fi")
        viewModel.setStudioFilter("Paramount")
        // Only movie-1 (Arrival) is both Sci-Fi and Paramount.
        XCTAssertEqual(viewModel.availableDecades, [2010])
    }

    /// The other half of the ask: clearing a filter should widen the other
    /// facets' options back out, not leave them stuck narrowed. Falls out
    /// for free from these being plain computed properties, but worth
    /// pinning down explicitly.
    func test_availableOptions_widenBackOutWhenAFilterIsCleared() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableStudios, ["Paramount"])

        viewModel.setGenreFilter(nil)

        XCTAssertEqual(viewModel.availableStudios, ["Paramount", "Warner Bros."])
    }

    func test_availableOptions_resetFilters_widensEverythingBackOut() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        viewModel.setStudioFilter("Paramount")
        viewModel.setDecadeFilter(2010)

        viewModel.resetFilters()

        XCTAssertEqual(viewModel.availableGenres, ["Action", "Drama", "Sci-Fi"])
        XCTAssertEqual(viewModel.availableStudios, ["Paramount", "Warner Bros."])
        XCTAssertEqual(viewModel.availableDecades, [2010, 1990])
    }

    /// Multiple active facets combine with AND, not OR.
    func test_filteredItems_combinesFiltersAcrossFacets() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setStudioFilter("Warner Bros.")
        viewModel.setDecadeFilter(2010)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-3"], "Only Inception is both Warner Bros. and 2010s")
    }

    func test_filteredItems_clearingAFilter_restoresThoseItems() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.filteredItems.count, 1)

        viewModel.setGenreFilter(nil)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-2", "movie-3"])
    }

    func test_filteredItems_noMatches_returnsEmpty() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        viewModel.setStudioFilter("Warner Bros.")
        XCTAssertTrue(viewModel.filteredItems.isEmpty, "No movie is both Drama and Warner Bros.")
    }

    // MARK: watched/favorites filters

    func test_availableWatchStatuses_bothPresentWhenNoOtherFilterActive() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.availableWatchStatuses, [.watched, .unwatched])
    }

    func test_filteredItems_byWatchStatus_watched() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setWatchStatusFilter(.watched)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1"])
    }

    func test_filteredItems_byWatchStatus_unwatched() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setWatchStatusFilter(.unwatched)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-2", "movie-3"])
    }

    func test_availableFavoriteStatuses_bothPresentWhenNoOtherFilterActive() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertEqual(viewModel.availableFavoriteStatuses, [.favorite, .nonFavorite])
    }

    func test_filteredItems_byFavoriteStatus_favorite() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setFavoriteStatusFilter(.favorite)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-2"])
    }

    func test_filteredItems_byFavoriteStatus_nonFavorite() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setFavoriteStatusFilter(.nonFavorite)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-3"])
    }

    func test_filteredItems_favoriteStatus_clearedRestoresEverything() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setFavoriteStatusFilter(.favorite)
        XCTAssertEqual(viewModel.filteredItems.count, 1)

        viewModel.setFavoriteStatusFilter(nil)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-2", "movie-3"])
    }

    /// Same cascading behavior as genre/studio/decade: watch-status and
    /// favorites narrow the *other* facets, and are themselves narrowed by
    /// the others — not exempt from the funnel just because they're
    /// user-data-derived rather than metadata-derived.
    func test_availableWatchStatuses_narrowedByOtherActiveFacets() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableWatchStatuses, [.watched], "Only movie-1 (watched) is Drama")
    }

    func test_availableFavoriteStatuses_narrowedByOtherActiveFacets() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.availableFavoriteStatuses, [.nonFavorite], "movie-1, the only Drama film, isn't a favorite")
    }

    func test_availableGenres_narrowedBySelectedWatchStatus() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setWatchStatusFilter(.watched)
        XCTAssertEqual(viewModel.availableGenres, ["Drama", "Sci-Fi"], "Only movie-1 is watched")
    }

    func test_availableGenres_narrowedByFavoriteStatus() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setFavoriteStatusFilter(.favorite)
        XCTAssertEqual(viewModel.availableGenres, ["Action", "Sci-Fi"], "Only movie-2 is a favorite")
    }

    // MARK: randomItem

    func test_randomItem_picksFromFilteredItems() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        XCTAssertEqual(viewModel.randomItem()?.id, "movie-1", "Only one match — the \"random\" pick is deterministic")
    }

    func test_randomItem_nilWhenNothingMatchesActiveFilters() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Drama")
        viewModel.setStudioFilter("Warner Bros.")
        XCTAssertNil(viewModel.randomItem())
    }

    // MARK: hasActiveFilters / resetFilters

    func test_hasActiveFilters_falseWhenNoneSelected() async {
        let viewModel = await makeLoadedViewModel()
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    func test_hasActiveFilters_trueWhenAnySingleFilterSelected() async {
        let genreOnly = await makeLoadedViewModel()
        genreOnly.setGenreFilter("Drama")
        XCTAssertTrue(genreOnly.hasActiveFilters)

        let studioOnly = await makeLoadedViewModel()
        studioOnly.setStudioFilter("Paramount")
        XCTAssertTrue(studioOnly.hasActiveFilters)

        let decadeOnly = await makeLoadedViewModel()
        decadeOnly.setDecadeFilter(2010)
        XCTAssertTrue(decadeOnly.hasActiveFilters)

        let watchStatusOnly = await makeLoadedViewModel()
        watchStatusOnly.setWatchStatusFilter(.watched)
        XCTAssertTrue(watchStatusOnly.hasActiveFilters)

        let favoritesOnly = await makeLoadedViewModel()
        favoritesOnly.setFavoriteStatusFilter(.favorite)
        XCTAssertTrue(favoritesOnly.hasActiveFilters)
    }

    func test_resetFilters_clearsEveryFilterAndRestoresEverything() async {
        let viewModel = await makeLoadedViewModel()
        viewModel.setGenreFilter("Sci-Fi")
        viewModel.setStudioFilter("Warner Bros.")
        viewModel.setDecadeFilter(2010)
        viewModel.setWatchStatusFilter(.unwatched)
        viewModel.setFavoriteStatusFilter(.favorite)
        XCTAssertTrue(viewModel.hasActiveFilters)

        viewModel.resetFilters()

        XCTAssertFalse(viewModel.hasActiveFilters)
        XCTAssertNil(viewModel.selectedGenre)
        XCTAssertNil(viewModel.selectedStudio)
        XCTAssertNil(viewModel.selectedDecade)
        XCTAssertNil(viewModel.selectedWatchStatus)
        XCTAssertNil(viewModel.selectedFavoriteStatus)
        XCTAssertEqual(viewModel.filteredItems.map(\.id), ["movie-1", "movie-2", "movie-3"])
    }
}
