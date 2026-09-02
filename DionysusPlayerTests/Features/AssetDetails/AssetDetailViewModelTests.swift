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

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try await super.tearDown()
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

    /// AUDIO SUPPRESSION: `item`/`displayedItemID` still populate (so
    /// `AssetDetailView`'s `item.isAudioContent` check can render its "not
    /// supported" state), but nothing downstream of that fires — a pure
    /// efficiency guard, not required for the suppression itself (which
    /// lives in `AssetDetailView`).
    func test_load_audioItem_populatesItemButSkipsSimilarCollectionsAndSeasons() async {
        let itemDto = BaseItemDto(id: "track-1", name: "Bend", type: .audio, mediaType: "Audio")
        let viewModel = makeViewModel(itemID: "track-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/track-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?") — an audio item shouldn't trigger similar/collections/seasons fetches")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "track-1")
        XCTAssertTrue(viewModel.similar.isEmpty)
        XCTAssertTrue(viewModel.collections.isEmpty)
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
        let seriesDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let seasonDto = BaseItemDto(id: "season-1", name: "Season 1", type: .season)
        let viewModel = makeViewModel(itemID: "ep-5")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: episodeDto)
            case "/Users/user-1/Items/series-1":
                // `seriesItem` — see its own doc comment — needs its own
                // fetch for the Episode case, unlike Season/Series where
                // `item` is already the Show's own item.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seriesDto)
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
        XCTAssertEqual(viewModel.seriesItem?.id, "series-1", "the Show's own item, separate from `item`")
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

    /// `similar`/`collections`/`seasons` are all supplementary rails, not
    /// the page itself — a hiccup fetching any one of them shouldn't take
    /// down the whole page (hero, Play button, everything else that already
    /// loaded fine) the way it used to. Only that one rail should end up
    /// empty.
    func test_load_similarItemsFetchFails_stillLoadsSuccessfullyWithEverythingElseIntact() async {
        let itemDto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/movie-1/Similar":
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            case "/Users/user-1/Items": // BoxSets probe inside collectionsContaining
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "movie-1")
        XCTAssertTrue(viewModel.similar.isEmpty)
    }

    /// See the test above — same reasoning, `seasons` instead (the BoxSets
    /// probe inside `collectionsContaining` failing outright, rather than
    /// just one collection's own membership check, is covered here too).
    func test_load_seasonsFetchFails_stillLoadsSuccessfullyWithEverythingElseIntact() async {
        let itemDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let viewModel = makeViewModel(itemID: "series-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Shows/series-1/Seasons":
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            case "/Items/series-1/Similar", "/Users/user-1/Items", "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "series-1")
        XCTAssertTrue(viewModel.seasons.isEmpty)
    }

    /// A BoxSet's own children fetch (`collectionItems`) is scoped by
    /// `ParentId=<itemID>`, hitting the exact same `/Users/user-1/Items`
    /// path as the `collectionsContaining` BoxSets probe every `load()`
    /// call already makes — this pins that the two don't get confused for
    /// each other by asserting on the actual `ParentId` query param, not
    /// just the path.
    func test_load_boxSet_fetchesCollectionItems() async {
        let collectionDto = BaseItemDto(id: "collection-1", name: "The Trilogy", type: .boxSet)
        let movieDto = BaseItemDto(id: "movie-1", name: "Part One", type: .movie)
        let viewModel = makeViewModel(itemID: "collection-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/collection-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: collectionDto)
            case "/Items/collection-1/Similar":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                if request.queryDictionary["ParentId"] == "collection-1" {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [movieDto], totalRecordCount: 1))
                }
                // BoxSets probe inside collectionsContaining
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.item?.id, "collection-1")
        XCTAssertEqual(viewModel.collectionItems.map(\.id), ["movie-1"])
        XCTAssertTrue(viewModel.seasons.isEmpty)
    }

    /// Movies (and every other non-BoxSet kind) have no `ParentId`-scoped
    /// children of their own — `collectionItems` should stay untouched
    /// rather than firing a pointless fetch that would just come back empty.
    func test_load_movie_neverFetchesCollectionItems() async {
        let itemDto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/movie-1/Similar", "/Users/user-1/Items": // BoxSets probe inside collectionsContaining
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertTrue(viewModel.collectionItems.isEmpty)
    }

    /// A Playlist's own member items fetch (`orderedPlaylistItems`) hits
    /// the dedicated `/Playlists/{id}/Items` endpoint — distinct from
    /// `collectionItems`' `/Users/{id}/Items?ParentId=` — and preserves the
    /// server's own returned order rather than re-sorting. `track-1`
    /// (audio) is filtered out; `movie-1` and `ep-1` (video) both pass
    /// through, pinning that AUDIO SUPPRESSION applies per-member, not
    /// per-kind.
    func test_load_playlist_fetchesOrderedPlaylistItemsInServerOrderAndExcludesAudio() async {
        let playlistDto = BaseItemDto(id: "playlist-1", name: "Movie Night", type: .playlist, mediaType: "Video")
        let movieDto = BaseItemDto(id: "movie-1", name: "Toy Story", type: .movie)
        let trackDto = BaseItemDto(id: "track-1", name: "Interlude", type: .audio, mediaType: "Audio")
        let episodeDto = BaseItemDto(id: "ep-1", name: "Pilot", type: .episode, seriesName: "Top Gear")
        let viewModel = makeViewModel(itemID: "playlist-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: playlistDto)
            case "/Items/playlist-1/Similar", "/Users/user-1/Items": // BoxSets probe inside collectionsContaining
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Playlists/playlist-1/Items":
                XCTAssertEqual(request.queryDictionary["userId"], "user-1")
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [movieDto, trackDto, episodeDto], totalRecordCount: 3)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.orderedPlaylistItems.map(\.id), ["movie-1", "ep-1"], "server order preserved, audio member dropped")
    }

    // MARK: playlistResumeTarget

    func test_playlistResumeTarget_firstUnplayedMember() async {
        let playlistDto = BaseItemDto(id: "playlist-1", name: "Movie Night", type: .playlist, mediaType: "Video")
        let watched = BaseItemDto(id: "movie-1", name: "Toy Story", type: .movie, userData: UserItemDataDto(played: true))
        let unwatched = BaseItemDto(id: "movie-2", name: "Cars", type: .movie, userData: UserItemDataDto(played: false))
        let viewModel = makeViewModel(itemID: "playlist-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: playlistDto)
            case "/Items/playlist-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Playlists/playlist-1/Items":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [watched, unwatched], totalRecordCount: 2)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.playlistResumeTarget?.id, "movie-2", "movie-1 is already fully played")
    }

    func test_playlistResumeTarget_everyMemberPlayed_fallsBackToFirst() async {
        let playlistDto = BaseItemDto(id: "playlist-1", name: "Movie Night", type: .playlist, mediaType: "Video")
        let first = BaseItemDto(id: "movie-1", name: "Toy Story", type: .movie, userData: UserItemDataDto(played: true))
        let second = BaseItemDto(id: "movie-2", name: "Cars", type: .movie, userData: UserItemDataDto(played: true))
        let viewModel = makeViewModel(itemID: "playlist-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: playlistDto)
            case "/Items/playlist-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Playlists/playlist-1/Items":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [first, second], totalRecordCount: 2)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.playlistResumeTarget?.id, "movie-1", "a full replay starts over from the beginning")
    }

    func test_playlistResumeTarget_nilWhenOrderedPlaylistItemsIsEmpty() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
        }
        await viewModel.load()

        XCTAssertNil(viewModel.playlistResumeTarget)
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

    // MARK: toggleFavorite(itemID:currentlyFavorite:) / toggleWatched(itemID:currentlyWatched:)

    func test_toggleFavorite_currentlyFalse_favoritesThenPatchesItemFromARefetch() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Items/movie-1" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.item?.isFavorite, false, "sanity check")

        var favoriteRequestMethod: String?
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/FavoriteItems/movie-1":
                favoriteRequestMethod = request.httpMethod
                return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "movie-1", name: "Arrival", type: .movie,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: false, isFavorite: true)
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.toggleFavorite(itemID: "movie-1", currentlyFavorite: false)

        XCTAssertEqual(favoriteRequestMethod, "POST", "favoriting (currently false) should POST")
        XCTAssertEqual(viewModel.item?.isFavorite, true, "should reflect the refetch, not just assume the toggle succeeded")
    }

    func test_toggleFavorite_currentlyTrue_sendsDELETE() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
        }
        await viewModel.load()

        var favoriteRequestMethod: String?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/FavoriteItems/movie-1" {
                favoriteRequestMethod = request.httpMethod
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
        }

        await viewModel.toggleFavorite(itemID: "movie-1", currentlyFavorite: true)

        XCTAssertEqual(favoriteRequestMethod, "DELETE", "unfavoriting (currently true) should DELETE")
    }

    func test_toggleWatched_currentlyFalse_marksWatchedThenPatchesItem() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
        }
        await viewModel.load()

        var watchedRequestMethod: String?
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/PlayedItems/movie-1":
                watchedRequestMethod = request.httpMethod
                return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
            case "/Users/user-1/Items/movie-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "movie-1", name: "Arrival", type: .movie,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: 100, played: true)
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.toggleWatched(itemID: "movie-1", currentlyWatched: false)

        XCTAssertEqual(watchedRequestMethod, "POST")
        XCTAssertEqual(viewModel.item?.isPlayed, true)
    }

    /// The favorite/watched refetch patches *every* property currently
    /// holding that same id, not just `item` — a Season tapped from
    /// `PlayResumeButtonRow`'s extended menu lives in `seasons`, not `item`.
    func test_toggleFavorite_patchesSeasonsEntryWhenTargetIsASeason() async {
        let seasonDto = BaseItemDto(id: "season-1", name: "Season 1", type: .season)
        let viewModel = makeViewModel(itemID: "series-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "series-1", name: "The Wire", type: .series))
            case "/Shows/series-1/Seasons":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [seasonDto], totalRecordCount: 1))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.seasons.first?.isFavorite, false, "sanity check")

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/FavoriteItems/season-1":
                return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
            case "/Users/user-1/Items/season-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "season-1", name: "Season 1", type: .season,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: false, isFavorite: true)
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.toggleFavorite(itemID: "season-1", currentlyFavorite: false)

        XCTAssertEqual(viewModel.seasons.first?.isFavorite, true)
        XCTAssertEqual(viewModel.item?.id, "series-1", "the Series itself (a different id) should be untouched")
    }

    /// The live bug this exists to fix (2026-08-16): confirmed against a
    /// real server that a favorite/watched write can return success
    /// immediately but not actually commit server-side for several
    /// *minutes* — an order of magnitude past `userDataCommitPollSchedule`'s
    /// ~13s budget. Before `applyOptimisticFavoriteWatched` existed, the
    /// poll below kept re-fetching that still-stale value and patching it
    /// straight into `item` on *every* attempt (not just once it actually
    /// confirmed), so once the poll gave up, `item` was left showing the
    /// pre-toggle value — indistinguishable from the tap having done
    /// nothing. Same "ignore unconfirmed fetches, keep the known-correct
    /// value" shape as `test_refreshItemAfterOptimisticUpdate_serverNeverCatchesUp_keepsOptimisticValue`
    /// above, for the favorite/watched poll instead of the playback-position
    /// one.
    func test_toggleFavorite_serverNeverConfirms_keepsOptimisticValueRatherThanRegressingToStaleData() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.item?.isFavorite, false, "sanity check")

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/FavoriteItems/movie-1":
                return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
            case "/Users/user-1/Items/movie-1":
                // The write above returned success, but every re-fetch still
                // reports the server's old, not-yet-committed value — the
                // real, confirmed-live scenario this test pins.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "movie-1", name: "Arrival", type: .movie,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: false, isFavorite: false)
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.toggleFavorite(itemID: "movie-1", currentlyFavorite: false)

        XCTAssertEqual(
            viewModel.item?.isFavorite, true,
            "the write succeeded, so the optimistic value should stick even though the server never confirmed it"
        )
    }

    // MARK: currentFavoriteWatchedStatus(forItemID:)

    /// `HeroActionButtons` calls this right when a toggle fires rather than
    /// trusting its own button/menu-row closure's captured `MediaItem` — see
    /// this method's own doc comment for the real, confirmed toolbar
    /// staleness bug that motivated it. Pins that it actually finds the
    /// right value across all four possible targets, and `nil` for anything
    /// that doesn't match one.
    func test_currentFavoriteWatchedStatus_findsTheRightTargetAmongItemSeriesItemShowPlaybackEpisodeAndSeasons() async {
        let viewModel = await loadedSeriesViewModel(
            nextUpItems: [BaseItemDto(id: "episode-1", name: "Pilot", type: .episode, userData: UserItemDataDto(isFavorite: true))],
            episodesItems: []
        )

        XCTAssertEqual(viewModel.currentFavoriteWatchedStatus(forItemID: "series-1")?.favorite, false, "matches item/seriesItem (same id for a Series-direct page)")
        XCTAssertEqual(viewModel.currentFavoriteWatchedStatus(forItemID: "episode-1")?.favorite, true, "matches showPlaybackEpisode (NextUp)")
        XCTAssertNil(viewModel.currentFavoriteWatchedStatus(forItemID: "nonexistent-id"))
    }

    // MARK: track(_:) / cancelBackgroundWork()

    /// `toggleFavorite`'s confirmation poll can run for up to ~13s
    /// (`refetchFavoriteWatchedTarget`'s retry schedule) — `AssetDetailView`
    /// backing out mid-poll shouldn't leave that running to completion
    /// against a screen nobody's looking at anymore. Simulates that by
    /// never actually confirming the toggle server-side (every refetch
    /// keeps reporting `isFavorite: false`, which would otherwise exhaust
    /// the entire retry schedule) and cancelling shortly after starting —
    /// a `refetchCount` well short of the full schedule is what proves the
    /// poll loop's own `Task.isCancelled` check actually stopped it early,
    /// not just that the outer `Task` was marked cancelled while the loop
    /// kept running regardless.
    func test_cancelBackgroundWork_stopsAnInFlightFavoriteTogglePoll() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Users/user-1/Items/movie-1" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "movie-1", name: "Arrival", type: .movie))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        await viewModel.load()

        nonisolated(unsafe) var refetchCount = 0
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/FavoriteItems/movie-1":
                return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
            case "/Users/user-1/Items/movie-1":
                refetchCount += 1
                // Never actually confirms — every attempt still reads
                // `isFavorite: false`, so nothing but cancellation would
                // ever stop this loop short of its full 7-attempt schedule.
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "movie-1", name: "Arrival", type: .movie,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: false, isFavorite: false)
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        let task = Task { await viewModel.toggleFavorite(itemID: "movie-1", currentlyFavorite: false) }
        viewModel.track(task)
        try? await Task.sleep(for: .milliseconds(50))
        viewModel.cancelBackgroundWork()
        await task.value

        XCTAssertLessThan(refetchCount, 7, "cancellation should stop the poll well before exhausting its full retry schedule")
    }

    // MARK: selectEpisode(_:)

    /// `SeasonEpisodeList`'s row-text tap (as opposed to its play button) —
    /// switches `item` to the tapped episode in place, on a Series-direct
    /// page, without touching `seriesID`/`seasons` (still the same Show).
    /// Does update `preselectedSeasonID` to the tapped episode's own season
    /// — a same-value reassignment for this caller specifically (the tapped
    /// episode is always within whichever season is already selected), but
    /// see `selectEpisode`'s own doc comment for why that's not true of
    /// every caller.
    func test_selectEpisode_swapsItemToTheEpisodeWithoutTouchingSeriesOrSeasons() async {
        let viewModel = await loadedSeriesViewModel(nextUpItems: [], episodesItems: [])
        let selectedEpisodeDto = BaseItemDto(id: "ep-7", name: "Ep 7", type: .episode, seasonId: "season-1")
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Users/user-1/Items/ep-7" else {
                XCTFail("selectEpisode should fetch the tapped episode's own full item — got \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: selectedEpisodeDto)
        }

        await viewModel.selectEpisode("ep-7")

        XCTAssertEqual(viewModel.item?.id, "ep-7")
        XCTAssertEqual(viewModel.item?.kind, .episode)
        XCTAssertEqual(viewModel.seriesID, "series-1", "shouldn't change — still browsing the same show")
        XCTAssertEqual(viewModel.preselectedSeasonID, "season-1", "should follow the tapped episode's own season")
    }

    /// Regression test for `refreshItem()`'s `displayedItemID` guard (see
    /// that property's doc comment): after `selectEpisode(_:)`, the page is
    /// displaying an episode the view model wasn't even constructed with —
    /// `refreshItem()` (called after a playback session) has to re-fetch
    /// *that* episode, not fall back to the original `itemID`.
    func test_refreshItem_afterSelectEpisode_refetchesTheSelectedEpisodeNotTheOriginalItemID() async {
        let viewModel = await loadedSeriesViewModel(nextUpItems: [], episodesItems: [])
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "ep-7", name: "Ep 7", type: .episode))
        }
        await viewModel.selectEpisode("ep-7")

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-7":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-7", name: "Ep 7", type: .episode,
                    userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: 100, played: true)
                ))
            default:
                XCTFail("refreshItem() should re-fetch ep-7 (the selected episode), not series-1 — got \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.id, "ep-7")
        XCTAssertEqual(viewModel.item?.isPlayed, true)
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

    /// A movie played directly from `CollectionItemList`'s own play button
    /// never pushes into that movie's own detail page, so it never goes
    /// through *that* page's `refreshItem()` — this page's own `refreshItem()`
    /// (fired when its `fullScreenCover` closes, same as any other item)
    /// has to re-fetch `collectionItems` itself so the played movie's
    /// watched/progress overlay updates once the player closes.
    func test_refreshItem_boxSet_refetchesCollectionItems() async {
        let collectionDto = BaseItemDto(id: "collection-1", name: "The Trilogy", type: .boxSet)
        let movieDto = BaseItemDto(id: "movie-1", name: "Part One", type: .movie)
        // `played: true` differs from the initial load's `nil` (no
        // `userData` at all) — what actually makes the poll loop below
        // break after its very first attempt instead of exhausting its
        // whole schedule; the BoxSet's own `played` value itself isn't
        // otherwise meaningful to this test.
        let refreshedCollectionDto = BaseItemDto(
            id: "collection-1", name: "The Trilogy", type: .boxSet,
            userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: true)
        )
        let updatedMovieDto = BaseItemDto(
            id: "movie-1", name: "Part One", type: .movie,
            userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: true)
        )
        let viewModel = makeViewModel(itemID: "collection-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/collection-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: collectionDto)
            case "/Items/collection-1/Similar":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/user-1/Items":
                if request.queryDictionary["ParentId"] == "collection-1" {
                    return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [movieDto], totalRecordCount: 1))
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.collectionItems.first?.isPlayed, false, "sanity check")

        // Differs from the initial (all-nil) userData on the very first
        // poll attempt, same trick every other `refreshItem()` test in this
        // file uses to keep the poll loop from actually running out its
        // full schedule.
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/collection-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: refreshedCollectionDto)
            case "/Users/user-1/Items":
                XCTAssertEqual(request.queryDictionary["ParentId"], "collection-1")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [updatedMovieDto], totalRecordCount: 1))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.collectionItems.map(\.id), ["movie-1"])
        XCTAssertEqual(viewModel.collectionItems.first?.isPlayed, true)
    }

    /// `orderedPlaylistItems`' own refresh — same reasoning/shape as
    /// `test_refreshItem_boxSet_refetchesCollectionItems` just above: this
    /// page's own item poll never "catches up" for a Playlist either, so
    /// `refreshItem()` re-fetches `/Playlists/{id}/Items` unconditionally
    /// once that poll finishes, keeping `playlistResumeTarget` current
    /// after a playback session closes.
    func test_refreshItem_playlist_refetchesOrderedPlaylistItems() async {
        let playlistDto = BaseItemDto(id: "playlist-1", name: "Movie Night", type: .playlist, mediaType: "Video")
        let movieDto = BaseItemDto(id: "movie-1", name: "Toy Story", type: .movie, userData: UserItemDataDto(played: false))
        let refreshedPlaylistDto = BaseItemDto(
            id: "playlist-1", name: "Movie Night", type: .playlist,
            userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: true), mediaType: "Video"
        )
        let updatedMovieDto = BaseItemDto(
            id: "movie-1", name: "Toy Story", type: .movie,
            userData: UserItemDataDto(playbackPositionTicks: nil, playedPercentage: nil, played: true)
        )
        let viewModel = makeViewModel(itemID: "playlist-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: playlistDto)
            case "/Items/playlist-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Playlists/playlist-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [movieDto], totalRecordCount: 1))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.orderedPlaylistItems.first?.isPlayed, false, "sanity check")

        // Differs from the initial (all-nil) userData on the very first
        // poll attempt, same trick `test_refreshItem_boxSet_refetchesCollectionItems`
        // uses to keep the poll loop from running out its full schedule.
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: refreshedPlaylistDto)
            case "/Playlists/playlist-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [updatedMovieDto], totalRecordCount: 1))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.orderedPlaylistItems.map(\.id), ["movie-1"])
        XCTAssertEqual(viewModel.orderedPlaylistItems.first?.isPlayed, true)
    }

    /// Regression test for a live bug report (2026-08-13): resuming a
    /// movie, scrubbing to a different position, and exiting within a few
    /// seconds left the detail page's progress bar showing the pre-scrub
    /// position, even though the server had actually committed the new one
    /// correctly (confirmed by Resume itself picking up the right spot).
    /// Simulates the server needing a few poll attempts before it reflects
    /// the change — `userDataCommitPollSchedule`'s whole reason for
    /// existing — pinning that `refreshItem()` actually keeps polling
    /// rather than giving up after the first miss.
    func test_refreshItem_serverConfirmsOnALaterAttempt_stillPicksUpTheChange() async {
        let staleTicks: Int64 = 10_000_000_000 // 1000s / ~16.7min
        let updatedTicks: Int64 = 90_000_000_000 // 9000s / 150min
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie,
                userData: UserItemDataDto(playbackPositionTicks: staleTicks, playedPercentage: 10, played: false)
            ))
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.item?.dto.userData?.playbackPositionTicks, staleTicks, "sanity check")

        var attempt = 0
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Users/user-1/Items/movie-1" else {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
            attempt += 1
            // First two attempts still return the pre-scrub position, as if
            // the server hasn't committed the write yet — only the third
            // reflects the real, scrubbed-to position.
            let ticks = attempt < 3 ? staleTicks : updatedTicks
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie,
                userData: UserItemDataDto(playbackPositionTicks: ticks, playedPercentage: 10, played: false)
            ))
        }

        await viewModel.refreshItem()

        XCTAssertEqual(attempt, 3, "should have kept polling past the first two stale responses")
        XCTAssertEqual(viewModel.item?.dto.userData?.playbackPositionTicks, updatedTicks)
    }

    /// Regression test for the actual live bug (2026-08-13, found *after*
    /// the two tests above shipped and the reported symptom persisted
    /// unchanged): those tests only exercised `refreshItem()` on its own —
    /// in real usage it always runs immediately after
    /// `applyOptimisticPlaybackPosition(_:)`, from the same close-and-return
    /// flow, and *that* combination had a real bug neither test caught.
    /// `refreshItem()`'s poll captured its "did this change?" baseline from
    /// `item` *after* the optimistic update had already set it to the
    /// correct new position — so the poll's first attempt, which almost
    /// always still gets the server's old, not-yet-committed value back,
    /// looked like "a change" against that baseline and got adopted
    /// immediately, silently undoing the optimistic fix. This pins the fix:
    /// a stale first/second attempt must be ignored, and only a fetch that's
    /// actually caught up (within `optimisticPositionTolerance`) gets adopted.
    func test_refreshItemAfterOptimisticUpdate_ignoresStaleFetchesUntilServerCatchesUp() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie, runTimeTicks: 10_000 * 10_000_000,
                userData: UserItemDataDto(playbackPositionTicks: 1_000 * 10_000_000, playedPercentage: 10, played: false)
            ))
        }
        await viewModel.load()

        // What `PlayerView.close()` does immediately on exit, before
        // `refreshItem()` even starts.
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "movie-1", positionSeconds: 9000, durationSeconds: 10_000))
        XCTAssertEqual(viewModel.item?.resumePositionSeconds, 9000, "sanity check")

        var attempt = 0
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Users/user-1/Items/movie-1" else {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
            attempt += 1
            // First two attempts are the server's old, not-yet-committed
            // position (the case that used to get wrongly adopted); only
            // the third has actually caught up.
            let ticks: Int64 = attempt < 3 ? 1_000 * 10_000_000 : 9000 * 10_000_000
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie, runTimeTicks: 10_000 * 10_000_000,
                userData: UserItemDataDto(playbackPositionTicks: ticks, playedPercentage: 10, played: false)
            ))
        }

        await viewModel.refreshItem()

        XCTAssertEqual(attempt, 3, "should have ignored the first two stale fetches rather than adopting the first one")
        XCTAssertEqual(viewModel.item?.resumePositionSeconds, 9000)
    }

    /// Same setup, but the server never catches up within the whole poll
    /// window — the known-correct optimistic value should stay on screen
    /// rather than the loop falling back to whatever stale data it last saw.
    func test_refreshItemAfterOptimisticUpdate_serverNeverCatchesUp_keepsOptimisticValue() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie, runTimeTicks: 10_000 * 10_000_000,
                userData: UserItemDataDto(playbackPositionTicks: 1_000 * 10_000_000, playedPercentage: 10, played: false)
            ))
        }
        await viewModel.load()
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "movie-1", positionSeconds: 9000, durationSeconds: 10_000))

        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Users/user-1/Items/movie-1" else {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie, runTimeTicks: 10_000 * 10_000_000,
                userData: UserItemDataDto(playbackPositionTicks: 1_000 * 10_000_000, playedPercentage: 10, played: false)
            ))
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.resumePositionSeconds, 9000, "should keep the known-correct optimistic value rather than regress to stale server data")
    }

    /// `SeasonEpisodeList` folds `episodeListRefreshToken` into its own
    /// episode-list fetch so a just-finished episode's row (progress bar/
    /// watched state) doesn't sit stale after returning from the player —
    /// see that property's own doc comment. Pinning that it actually
    /// changes on every `refreshItem()` call is what that wiring depends on.
    func test_refreshItem_changesEpisodeListRefreshToken() async {
        let viewModel = await loadedSeriesViewModel(nextUpItems: [], episodesItems: [])
        let tokenBefore = viewModel.episodeListRefreshToken
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "series-1", name: "The Wire", type: .series))
        }

        await viewModel.refreshItem()

        XCTAssertNotEqual(viewModel.episodeListRefreshToken, tokenBefore)
    }

    // MARK: applyOptimisticPlaybackPosition(_:)

    /// The direct fix for the same live bug report above: rather than rely
    /// on any poll to catch up, `PlayerView` reports its own final position
    /// back immediately, and this applies it synchronously — no network
    /// round trip, nothing to race.
    func test_applyOptimisticPlaybackPosition_matchingItem_updatesResumePositionImmediately() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie, runTimeTicks: 100 * 10_000_000,
                userData: UserItemDataDto(playbackPositionTicks: 10 * 10_000_000, playedPercentage: 10, played: false)
            ))
        }
        await viewModel.load()

        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "movie-1", positionSeconds: 90, durationSeconds: 100))

        XCTAssertEqual(viewModel.item?.resumePositionSeconds, 90)
    }

    /// Show content's Play/Resume button targets `showPlaybackEpisode`, not
    /// `item` (the Show itself) — see `PlayResumeButtonRow.targetEpisode`'s
    /// doc comment — so that's what a playback session for one of its
    /// episodes needs to patch instead.
    func test_applyOptimisticPlaybackPosition_matchingShowPlaybackEpisode_updatesIt() async {
        let episodeDto = BaseItemDto(
            id: "ep-4", name: "Old Cases", type: .episode, runTimeTicks: 100 * 10_000_000,
            userData: UserItemDataDto(playbackPositionTicks: 10 * 10_000_000, playedPercentage: 10, played: false)
        )
        let viewModel = await loadedSeriesViewModel(nextUpItems: [episodeDto], episodesItems: [])
        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-4", "sanity check")

        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "ep-4", positionSeconds: 90, durationSeconds: 100))

        XCTAssertEqual(viewModel.showPlaybackEpisode?.resumePositionSeconds, 90)
        XCTAssertNil(viewModel.item?.resumePositionSeconds, "item is the Series itself here, not the episode — shouldn't be touched")
    }

    /// A playlist's main Play/Resume button targets `playlistResumeTarget`
    /// (one of `orderedPlaylistItems`), not `item` (the Playlist itself,
    /// which has no `MediaSources`/resume position of its own) — see
    /// `PlaylistDetailView`'s doc comment — so that's the array a
    /// just-closed playback session needs to patch.
    func test_applyOptimisticPlaybackPosition_matchingOrderedPlaylistItem_updatesIt() async {
        let playlistDto = BaseItemDto(id: "playlist-1", name: "Movie Night", type: .playlist, mediaType: "Video")
        let movieDto = BaseItemDto(
            id: "movie-1", name: "Toy Story", type: .movie, runTimeTicks: 100 * 10_000_000,
            userData: UserItemDataDto(playbackPositionTicks: 10 * 10_000_000, playedPercentage: 10, played: false)
        )
        let viewModel = makeViewModel(itemID: "playlist-1")
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/playlist-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: playlistDto)
            case "/Items/playlist-1/Similar", "/Users/user-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Playlists/playlist-1/Items":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [movieDto], totalRecordCount: 1))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }
        await viewModel.load()

        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "movie-1", positionSeconds: 90, durationSeconds: 100))

        XCTAssertEqual(viewModel.orderedPlaylistItems.first?.resumePositionSeconds, 90)
    }

    func test_applyOptimisticPlaybackPosition_nonMatchingItemID_isANoOp() async {
        let viewModel = makeViewModel(itemID: "movie-1")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                id: "movie-1", name: "Saving Private Ryan", type: .movie,
                userData: UserItemDataDto(playbackPositionTicks: 10 * 10_000_000)
            ))
        }
        await viewModel.load()

        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "some-other-item", positionSeconds: 90, durationSeconds: 100))

        XCTAssertEqual(viewModel.item?.resumePositionSeconds, 10)
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

    /// Episode-content counterpart to `loadedSeriesViewModel` above — `item`
    /// is the episode itself (`itemID`'s own `.episode` DTO), not the Show.
    private func loadedEpisodeViewModel(itemID: String = "ep-5", seasonId: String = "season-1") async -> AssetDetailViewModel {
        let episodeDto = BaseItemDto(id: itemID, name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: seasonId)
        let seriesDto = BaseItemDto(id: "series-1", name: "The Wire", type: .series)
        let viewModel = makeViewModel(itemID: itemID)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: episodeDto)
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: seriesDto)
            default:
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

    // MARK: advanceToNextEpisodeIfCompleted() (refreshItem()'s next-episode advance)

    /// The user-facing feature this all exists for (2026-08-13): once the
    /// server confirms a just-played episode is fully watched, and
    /// Jellyfin's own NextUp resolves to a *different* episode, the detail
    /// page should advance to show it — instead of sitting on the
    /// just-finished episode until the user manually picks the next one.
    /// Covers the Episode-content entry point (deep link, Home's Continue
    /// Watching, `selectEpisode`); `test_refreshItem_seriesDirect_confirmedPlayed_advancesPageToNextEpisode`
    /// below covers the Series-direct entry point.
    ///
    /// Also exercises the season-boundary case: `ep-6` (the resolved next
    /// episode) is in a *different* season than `ep-5` (the one just
    /// finished) — `preselectedSeasonID` should follow it, which is what
    /// `ShowDetailView`'s own `.onChange(of: viewModel.item?.id)` then uses
    /// to keep its season picker in sync.
    func test_refreshItem_episodeContent_confirmedPlayed_advancesToNextEpisode() async {
        let viewModel = await loadedEpisodeViewModel()
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "ep-5", positionSeconds: 1400, durationSeconds: 1400))

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-5", name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: "season-1",
                    userData: UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 100, played: true)
                ))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(
                    items: [BaseItemDto(id: "ep-6", name: "Ep 6", type: .episode, seriesId: "series-1", seasonId: "season-2")],
                    totalRecordCount: 1
                ))
            case "/Users/user-1/Items/ep-6":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-6", name: "Ep 6", type: .episode, seriesId: "series-1", seasonId: "season-2"
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.id, "ep-6", "should advance to the resolved next episode")
        XCTAssertEqual(viewModel.preselectedSeasonID, "season-2", "should track the new episode's own season, crossing the boundary from season-1")
    }

    /// Same confirmation as the Episode-content test above, but starting
    /// from a Series-direct page — see `advanceToNextEpisodeIfCompleted`'s
    /// own doc comment for why this is the *same* mechanism, not a special
    /// case: `isEpisodeContent` is purely `item?.kind == .episode`, so once
    /// `item` swaps to the resolved next episode, the page becomes Episode
    /// content with no further branching needed.
    ///
    /// The Series' own DTO (`series-1`, what the *other* concurrent poll in
    /// `refreshItem()` fetches) deliberately never changes here, to confirm
    /// this advance doesn't depend on that poll detecting anything — see
    /// `refreshShowPlaybackEpisodeIfNeeded`'s doc comment for why it
    /// essentially never would in real usage either.
    func test_refreshItem_seriesDirect_confirmedPlayed_advancesPageToNextEpisode() async {
        let firstNextUp = BaseItemDto(id: "ep-5", name: "Ep 5", type: .episode)
        let viewModel = await loadedSeriesViewModel(nextUpItems: [firstNextUp], episodesItems: [])
        XCTAssertEqual(viewModel.showPlaybackEpisode?.id, "ep-5", "sanity check")
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "ep-5", positionSeconds: 1400, durationSeconds: 1400))

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/series-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "series-1", name: "The Wire", type: .series))
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-5", name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: "season-1",
                    userData: UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 100, played: true)
                ))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(
                    items: [BaseItemDto(id: "ep-6", name: "Ep 6", type: .episode, seriesId: "series-1", seasonId: "season-1")], totalRecordCount: 1
                ))
            case "/Users/user-1/Items/ep-6":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-6", name: "Ep 6", type: .episode, seriesId: "series-1", seasonId: "season-1"
                ))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.id, "ep-6", "the Series-direct page should advance to the next episode, becoming Episode content")
        XCTAssertEqual(viewModel.item?.kind, .episode)
    }

    /// NextUp having nothing left (the show is finished) is indistinguishable
    /// from "nothing to advance to yet" — should leave the just-finished
    /// episode on screen rather than erroring or clearing `item`.
    func test_refreshItem_episodeContent_confirmedPlayed_nextUpEmpty_staysOnFinishedEpisode() async {
        let viewModel = await loadedEpisodeViewModel()
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "ep-5", positionSeconds: 1400, durationSeconds: 1400))

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-5", name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: "season-1",
                    userData: UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 100, played: true)
                ))
            case "/Shows/NextUp":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertEqual(viewModel.item?.id, "ep-5", "series finished — nothing to advance to, should stay put")
    }

    /// The server never actually confirming `played` within the poll
    /// window (still mid-watch, or a slow write) should never advance —
    /// NextUp shouldn't even be consulted on a guess. Runs the full poll
    /// schedule (~13s, same accepted cost as
    /// `test_refreshItemAfterOptimisticUpdate_serverNeverCatchesUp_keepsOptimisticValue`
    /// above).
    func test_refreshItem_episodeContent_neverConfirmedPlayed_doesNotAdvance() async {
        let viewModel = await loadedEpisodeViewModel()
        viewModel.applyOptimisticPlaybackPosition(PlaybackSessionOutcome(itemID: "ep-5", positionSeconds: 1400, durationSeconds: 1400))

        var nextUpWasConsulted = false
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/ep-5":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(
                    id: "ep-5", name: "Ep 5", type: .episode, seriesId: "series-1", seasonId: "season-1",
                    userData: UserItemDataDto(playbackPositionTicks: 1_000_000_000, playedPercentage: 99, played: false)
                ))
            case "/Shows/NextUp":
                nextUpWasConsulted = true
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            }
        }

        await viewModel.refreshItem()

        XCTAssertFalse(nextUpWasConsulted, "shouldn't even consult NextUp until played is actually confirmed")
        XCTAssertEqual(viewModel.item?.id, "ep-5")
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
