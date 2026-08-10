import XCTest
@testable import Dionysus

/// `AssetDetailViewModel` was previously untested. The things worth pinning
/// down: the movie/series/season/episode branches in `load()` (only
/// series/season/episode fetch `Seasons`; a Season swaps `item` to its
/// parent Series' own DTO while an Episode keeps `item` as itself — see
/// `AssetDetailViewModel.item`'s doc comment), `refreshItem()` re-fetching
/// `displayedItemID` rather than `itemID` for that same Season case, and
/// `showPlaybackEpisode`'s resolution — NextUp (in-progress/next-up episode
/// → first episode of the first season) for a Series tapped directly, but
/// always that specific season's own first episode for a Season tap.
@MainActor
final class AssetDetailViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.AssetDetailViewModelTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(itemID: String, preloadedItem: MediaItem? = nil) -> AssetDetailViewModel {
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        return AssetDetailViewModel(
            client: client, userID: "user-1", itemID: itemID, preloadedItem: preloadedItem,
            versionPreferenceStore: MediaVersionPreferenceStore(defaults: defaults)
        )
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
            case "/Items/series-1/Similar", "/Users/user-1/Items", "/Shows/NextUp", "/Shows/series-1/Episodes":
                // The latter two are `showPlaybackEpisode`'s own resolution
                // (see its doc comment) — not this test's concern, so left
                // empty; covered by its own tests further down.
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

    /// A Season tapped directly (deep link, or a future season-level
    /// browsing entry point) swaps `item` to the parent *Series'* own DTO —
    /// a Season has no overview/artwork/media of its own worth showing as
    /// this page's content — while `seriesID`/`preselectedSeasonID` are set
    /// so `ShowDetailView`'s season picker defaults to the tapped season
    /// rather than the first.
    func test_load_season_swapsItemToParentSeriesAndPreselectsThatSeason() async {
        let seasonDto = BaseItemDto(id: "season-2", name: "Season 2", type: .season, seriesId: "series-1")
        let seriesDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let allSeasons = [
            BaseItemDto(id: "season-1", name: "Season 1", type: .season),
            BaseItemDto(id: "season-2", name: "Season 2", type: .season),
        ]
        let viewModel = makeViewModel(itemID: "season-2")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/season-2":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seasonDto)
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seriesDto)
            case "/Shows/series-1/Seasons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: allSeasons, totalRecordCount: 2))
            case "/Items/series-1/Similar", "/Users/user-1/Items", "/Shows/series-1/Episodes":
                // The latter is `showPlaybackEpisode`'s own resolution (see
                // its doc comment) — not this test's concern, so left
                // empty; covered by its own test further down.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "series-1", "content should be the parent Series, not the tapped Season")
        XCTAssertEqual(viewModel.seriesID, "series-1")
        XCTAssertEqual(viewModel.preselectedSeasonID, "season-2")
        XCTAssertEqual(viewModel.seasons.map(\.id), ["season-1", "season-2"])
    }

    /// An Episode tapped directly (Home's Continue Watching rail, a search
    /// result, a deep link) keeps `item` as that episode itself — its own
    /// overview/artwork/technical details/versions are what actually show —
    /// while still resolving `seriesID`/`preselectedSeasonID` so
    /// `ShowDetailView` can render the season picker/episode list around it.
    func test_load_episode_keepsItemAsTheEpisodeButResolvesItsSeries() async {
        let episodeDto = BaseItemDto(
            id: "ep-5", name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: "season-1"
        )
        let seasonDto = BaseItemDto(id: "season-1", name: "Season 1", type: .season)
        let viewModel = makeViewModel(itemID: "ep-5")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: episodeDto)
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
        XCTAssertEqual(viewModel.item?.id, "ep-5", "content should stay the episode itself")
        XCTAssertEqual(viewModel.seriesID, "series-1")
        XCTAssertEqual(viewModel.preselectedSeasonID, "season-1")
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

    // MARK: preloadedItem

    /// `preloadedItem` — the `MediaItem` the pushing hero/poster card
    /// already had in hand — should be visible immediately, before `load()`
    /// or `loadIfNeeded()` ever runs. This is what lets `AssetDetailView`
    /// render a real page (and a zoom navigation transition land on
    /// something real) instead of a spinner the instant the push happens.
    func test_init_withPreloadedItem_seedsItemBeforeAnyLoad() {
        let images = ImageURLBuilder(baseURL: baseURL, accessToken: "tok")
        let preloaded = MediaItem(dto: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie), images: images)

        let viewModel = makeViewModel(itemID: "movie-1", preloadedItem: preloaded)

        XCTAssertEqual(viewModel.item?.id, "movie-1")
        XCTAssertEqual(viewModel.loadState, .idle, "Seeding item shouldn't itself count as having loaded")
    }

    /// Regression test for switching the `loadIfNeeded` guard from "item is
    /// nil" to "loadState == .idle": a preloaded item makes `item` non-nil
    /// immediately, which the old guard would have mistaken for "already
    /// loaded" and skipped fetching the full item (cast, technical details,
    /// similar/collections rails) entirely.
    func test_loadIfNeeded_withPreloadedItem_stillFetchesFullItem() async {
        let images = ImageURLBuilder(baseURL: baseURL, accessToken: "tok")
        let preloaded = MediaItem(dto: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie), images: images)
        let similarDto = BaseItemDto(id: "movie-2", name: "Contact", type: .movie)
        let viewModel = makeViewModel(itemID: "movie-1", preloadedItem: preloaded)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
            case "/Items/movie-1/Similar":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [similarDto], totalRecordCount: 1))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.similar.map(\.id), ["movie-2"], "The full fetch should still have run despite the preloaded item")
    }

    // MARK: refreshItem()

    /// Regression test for the Season case: `load()` swaps `item` to the
    /// parent Series' own DTO (see `test_load_season_...` above), so
    /// `refreshItem()` must re-fetch the *Series* afterward, not the
    /// originally-tapped Season — re-fetching `itemID` there would silently
    /// overwrite `item` with the Season's own (much sparser) DTO instead.
    func test_refreshItem_afterSeasonLoad_refetchesTheParentSeriesNotTheTappedSeason() async {
        let seasonDto = BaseItemDto(id: "season-2", name: "Season 2", type: .season, seriesId: "series-1")
        let seriesDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let refreshedSeriesDto = BaseItemDto(
            id: "series-1", name: "The Wire", type: .series,
            userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: 50, played: false)
        )
        let viewModel = makeViewModel(itemID: "season-2")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/season-2":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seasonDto)
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seriesDto)
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.item?.id, "series-1", "sanity check — see test_load_season_... above")

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: refreshedSeriesDto)
            case "/Shows/series-1/Episodes":
                // `refreshItem()` also re-resolves `showPlaybackEpisode` —
                // its own tests cover that; here it just needs tolerating
                // so it doesn't trip the `default` XCTFail below.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("refreshItem() should re-fetch the Series (series-1), not the tapped Season (season-2) — got \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.id, "series-1")
        XCTAssertEqual(viewModel.item?.dto.userData?.playedPercentage, 50)
    }

    // MARK: showPlaybackEpisode

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

    func test_load_movie_showPlaybackEpisodeStaysNil() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Items/movie-1" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()

        XCTAssertNil(viewModel.showPlaybackEpisode)
    }

    func test_load_seriesDirect_showPlaybackEpisode_prefersNextUpOverFirstEpisode() async {
        let nextUpEpisode = BaseItemDto(id: "ep-5", name: "Ep 5", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [nextUpEpisode], episodesItems: [])

        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-5")
    }

    func test_load_seriesDirect_showPlaybackEpisode_fallsBackToFirstEpisodeOfFirstSeasonWhenNoNextUp() async {
        let firstEpisode = BaseItemDto(id: "ep-1", name: "Ep 1", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [], episodesItems: [firstEpisode])

        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-1")
    }

    /// The crux of the "clearer Play/Resume CTA" feature: NextUp returning
    /// an in-progress episode (Jellyfin's own resume-in-place semantics —
    /// see `showPlaybackEpisode`'s doc comment) has to carry that episode's
    /// *own* `userData` through into `showPlaybackEpisode`, not just its id
    /// — `PlayResumeButtonRow` reads `effectiveItem.isPartWatched` straight
    /// off it to decide "Resume SXX:EYY" vs. "Play SXX:EYY".
    func test_load_seriesDirect_showPlaybackEpisode_carriesThroughItsOwnWatchedState() async {
        let inProgressEpisode = BaseItemDto(
            id: "ep-5", name: "Ep 5", type: .episode,
            userData: UserItemDataDto(playbackPositionTicks: 1_000_000, playedPercentage: 40, played: false)
        )
        let viewModel = await loadedSeriesViewModel(nextUpItems: [inProgressEpisode], episodesItems: [])

        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-5")
        XCTAssertTrue(viewModel.showPlaybackEpisode?.isPartWatched ?? false)
    }

    /// A Season tapped directly always targets *that season's own* first
    /// episode — confirmed behavior (not NextUp/"most recently watched
    /// across the whole show"): a Season tap reads as "start this season",
    /// not "continue the show overall". The `/Shows/NextUp` handler below
    /// would resolve to a *different* episode (`ep-5`) if it were ever
    /// consulted — asserting `ep-9` (from the season-scoped Episodes call)
    /// instead proves NextUp genuinely isn't part of this path, not just
    /// that the query happened to agree.
    ///
    /// Assertions run *after* `load()` returns, not inside the
    /// `requestHandler` closure itself — `MockURLProtocol` invokes it off
    /// the main actor, and running *any* closure literal there (not just an
    /// XCTest assertion — a plain `{ $0.name == "seasonId" }` predicate
    /// passed to `.first(where:)` triggers the identical trap) crashes
    /// with `swift_task_checkIsolatedSwift`, confirmed via a real crash
    /// log. Capturing only the plain `URL`/`Bool` values inside the
    /// handler and doing every closure-based computation (parsing the
    /// query string, then the assertions) back on the test method's own
    /// (`@MainActor`) context after `await` resumes is what avoids it —
    /// same reasoning as `requestCount` in
    /// `test_loadIfNeeded_doesNotRefetchOnceItemIsPopulated` above, just
    /// extended to cover *any* closure, not only assertion macros.
    func test_load_season_showPlaybackEpisode_targetsFirstEpisodeOfThatSeasonSpecifically() async {
        let seasonDto = BaseItemDto(id: "season-2", name: "Season 2", type: .season, seriesId: "series-1")
        let seriesDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let season2FirstEpisode = BaseItemDto(id: "ep-9", name: "Ep 9", type: .episode)
        let unrelatedNextUpEpisode = BaseItemDto(id: "ep-5", name: "Ep 5", type: .episode)
        let viewModel = makeViewModel(itemID: "season-2")
        var capturedEpisodesRequestURL: URL?
        var nextUpWasConsulted = false
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/season-2":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seasonDto)
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seriesDto)
            case "/Shows/series-1/Episodes":
                capturedEpisodesRequestURL = request.url
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [season2FirstEpisode], totalRecordCount: 1))
            case "/Shows/NextUp":
                nextUpWasConsulted = true
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [unrelatedNextUpEpisode], totalRecordCount: 1))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        let seasonIdParam = capturedEpisodesRequestURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }?.first(where: { $0.name == "seasonId" })?.value
        XCTAssertEqual(seasonIdParam, "season-2", "should query episodes for the tapped season specifically")
        XCTAssertFalse(nextUpWasConsulted, "Season-linked load() shouldn't consult NextUp at all")
        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-9")
    }

    /// `refreshItem()` also re-resolves `showPlaybackEpisode` for Show
    /// content, not just `item` itself — the previously-resolved episode
    /// may have just been fully watched, changing what NextUp should now
    /// point at.
    func test_refreshItem_seriesDirect_reResolvesShowPlaybackEpisode() async {
        let firstNextUp = BaseItemDto(id: "ep-5", name: "Ep 5", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [firstNextUp], episodesItems: [])
        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-5", "sanity check")

        let secondNextUp = BaseItemDto(id: "ep-6", name: "Ep 6", type: .episode)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "series-1", name: "The Wire", type: .series,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: 20, played: false)
                ))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [secondNextUp], totalRecordCount: 1))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-6")
    }

    // MARK: preferredMediaSourceID(forPlayableItem:) / setPreferredMediaSourceID(_:forPlayableItem:)
    // Thin wrappers around `MediaVersionPreferenceStore` (see its own tests
    // for the persistence/scoping behavior itself) — these just confirm the
    // wrapper actually plumbs this instance's `userID` through correctly.

    func test_preferredMediaSourceID_nilBeforeAnyChoiceIsRecorded() {
        let viewModel = makeViewModel(itemID: "movie-1")
        XCTAssertNil(viewModel.preferredMediaSourceID(forPlayableItem: "movie-1"))
    }

    func test_setPreferredMediaSourceID_isReadBackByPreferredMediaSourceID() {
        let viewModel = makeViewModel(itemID: "movie-1")
        viewModel.setPreferredMediaSourceID("src-1080p", forPlayableItem: "movie-1")
        XCTAssertEqual(viewModel.preferredMediaSourceID(forPlayableItem: "movie-1"), "src-1080p")
    }

    /// A Show's own Play button resolves to a specific *episode* (see
    /// `showPlaybackEpisode`), distinct from the Series' own `itemID` this
    /// view model was constructed with — the preference has to key off
    /// that resolved episode id, not the Series.
    func test_preferredMediaSourceID_keyedByThePlayableItemNotTheViewModelsOwnItemID() {
        let viewModel = makeViewModel(itemID: "series-1")
        viewModel.setPreferredMediaSourceID("src-1080p", forPlayableItem: "ep-5")

        XCTAssertEqual(viewModel.preferredMediaSourceID(forPlayableItem: "ep-5"), "src-1080p")
        XCTAssertNil(viewModel.preferredMediaSourceID(forPlayableItem: "series-1"))
    }
}
