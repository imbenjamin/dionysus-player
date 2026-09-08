import XCTest
@testable import Dionysus

/// Covers `AddToPlaylistSheet`'s view model: what the picker ends up listing,
/// and what the two "add" paths actually send.
///
/// The permission filtering itself lives in
/// `JellyfinAPIClient.editablePlaylists` (and is tested directly in
/// `JellyfinAPIClientTests`); these tests drive it through the view model so
/// the load-state transitions and the copy helpers are exercised against the
/// same responses the real screen sees.
@MainActor
final class AddToPlaylistViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    override func tearDown() async throws {
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        try await super.tearDown()
    }

    private func makeViewModel(target: MediaItem) -> AddToPlaylistViewModel {
        let client = JellyfinAPIClient(
            baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        return AddToPlaylistViewModel(client: client, userID: "user-1", target: target)
    }

    private func item(
        _ id: String, name: String = "Arrival", type: BaseItemKind = .movie, episodeCount: Int? = nil
    ) -> MediaItem {
        var dto = BaseItemDto(id: id, name: name, type: type)
        dto.recursiveItemCount = episodeCount
        return MediaItem(dto: dto, images: images)
    }

    private func playlistDTO(_ id: String, name: String, mediaType: String = "Video") -> BaseItemDto {
        var dto = BaseItemDto(id: id, name: name, type: .playlist)
        dto.mediaType = mediaType
        return dto
    }

    /// Installs the two request shapes a load makes. Captures nothing
    /// mutable and is never reassigned — the permission fan-out calls this
    /// from several threads at once, and mutating a local captured from an
    /// `@MainActor` test here hangs the run with no crash message. Assert on
    /// `MockURLProtocol.lastRequest` or the view model's own state instead.
    private func installLoadHandler(
        browse: [BaseItemDto],
        canEditByPlaylistID: [String: Bool],
        memberIDsByPlaylistID: [String: [String]] = [:],
        seriesEpisodes: [BaseItemDto] = []
    ) {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            // A show/season target resolves its own episodes first, so the
            // picker knows which playlists already hold all of them.
            if path.hasSuffix("/Episodes") {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: BaseItemDtoQueryResult(
                        items: seriesEpisodes, totalRecordCount: seriesEpisodes.count
                    )
                )
            }
            if path.hasSuffix("/Items") {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: BaseItemDtoQueryResult(items: browse, totalRecordCount: browse.count)
                )
            }
            guard path.contains("/Users/") else {
                let playlistID = String(path.dropFirst("/Playlists/".count))
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaylistDto(itemIds: memberIDsByPlaylistID[playlistID])
                )
            }
            let playlistID = path
                .replacingOccurrences(of: "/Playlists/", with: "")
                .components(separatedBy: "/Users/").first ?? ""
            guard let canEdit = canEditByPlaylistID[playlistID] else {
                return MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
            }
            return try MockURLProtocol.encodedJSONResponse(
                for: request, value: PlaylistUserPermissions(userId: "user-1", canEdit: canEdit)
            )
        }
    }

    // MARK: - Loading

    func test_load_listsOnlyPlaylistsThisUserMayEdit() async {
        let viewModel = makeViewModel(target: item("movie-1"))
        installLoadHandler(
            browse: [
                playlistDTO("pl-mine", name: "Weekend Watchlist"),
                playlistDTO("pl-readonly", name: "Shared With Me"),
                playlistDTO("pl-shared-editable", name: "Late Night")
            ],
            canEditByPlaylistID: ["pl-mine": true, "pl-shared-editable": true]
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.playlists.map(\.id), ["pl-mine", "pl-shared-editable"])
        XCTAssertEqual(viewModel.playlists.map(\.name), ["Weekend Watchlist", "Late Night"])
    }

    /// The empty result is a `.loaded` state, not a failure — the sheet still
    /// has "New Playlist" to offer, which needs no permission at all.
    func test_load_noEditablePlaylists_isLoadedAndEmptyRatherThanFailed() async {
        let viewModel = makeViewModel(target: item("movie-1"))
        installLoadHandler(
            browse: [playlistDTO("pl-readonly", name: "Shared With Me")],
            canEditByPlaylistID: [:]
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertTrue(viewModel.playlists.isEmpty)
    }

    func test_load_browseFailure_reportsFailedState() async {
        let viewModel = makeViewModel(target: item("movie-1"))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        await viewModel.load()

        guard case .failed = viewModel.loadState else {
            return XCTFail("Expected .failed, got \(viewModel.loadState)")
        }
        XCTAssertTrue(viewModel.playlists.isEmpty)
    }

    // MARK: - Already-added rows

    /// A playlist that already holds the target is marked so the sheet can
    /// grey its row out, rather than silently dropped from the list — a
    /// missing playlist reads as a failure, a ticked one reads as "done".
    func test_load_marksPlaylistsThatAlreadyContainASingleTarget() async {
        let viewModel = makeViewModel(target: item("movie-1"))
        installLoadHandler(
            browse: [playlistDTO("pl-has", name: "Has It"), playlistDTO("pl-hasnt", name: "Doesn't")],
            canEditByPlaylistID: ["pl-has": true, "pl-hasnt": true],
            memberIDsByPlaylistID: ["pl-has": ["movie-1", "movie-9"], "pl-hasnt": ["movie-9"]]
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.playlists.first { $0.id == "pl-has" }?.alreadyContainsTarget, true)
        XCTAssertEqual(viewModel.playlists.first { $0.id == "pl-hasnt" }?.alreadyContainsTarget, false)
    }

    /// **All**, not any. A playlist holding only some of a show's episodes
    /// is still worth offering — the user can top it up — so only a playlist
    /// containing every episode is marked.
    func test_load_showTarget_marksOnlyPlaylistsHoldingEveryEpisode() async {
        let viewModel = makeViewModel(target: item("series-1", type: .series))
        installLoadHandler(
            browse: [playlistDTO("pl-all", name: "All"), playlistDTO("pl-partial", name: "Partial")],
            canEditByPlaylistID: ["pl-all": true, "pl-partial": true],
            memberIDsByPlaylistID: [
                "pl-all": ["ep-1", "ep-2", "ep-3"],
                "pl-partial": ["ep-1", "ep-2"]
            ],
            seriesEpisodes: [item("ep-1"), item("ep-2"), item("ep-3")].map(\.dto)
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.playlists.first { $0.id == "pl-all" }?.alreadyContainsTarget, true)
        XCTAssertEqual(viewModel.playlists.first { $0.id == "pl-partial" }?.alreadyContainsTarget, false)
    }

    /// Fail-open: if the episode fetch didn't resolve, nothing is marked.
    /// Better a redundant add than a row the user can't tap for a reason
    /// they can't see.
    func test_load_unresolvedTarget_marksNothingAsAlreadyAdded() async {
        let viewModel = makeViewModel(target: item("series-1", type: .series))
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Episodes") {
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
            if path.hasSuffix("/Items") {
                let browse = [BaseItemDto(id: "pl-1", name: "Anything", type: .playlist)]
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: BaseItemDtoQueryResult(items: browse, totalRecordCount: 1)
                )
            }
            guard path.contains("/Users/") else {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaylistDto(itemIds: ["ep-1", "ep-2"])
                )
            }
            return try MockURLProtocol.encodedJSONResponse(
                for: request, value: PlaylistUserPermissions(userId: "user-1", canEdit: true)
            )
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.playlists.first?.alreadyContainsTarget, false)
    }

    // MARK: - Adding

    func test_add_sendsTheTargetsOwnID() async throws {
        let viewModel = makeViewModel(target: item("movie-7"))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        try await viewModel.add(to: "pl-mine")

        let request = MockURLProtocol.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/Playlists/pl-mine/Items")
        XCTAssertEqual(request?.queryDictionary["ids"], "movie-7")
        XCTAssertFalse(viewModel.isSubmitting, "isSubmitting must be cleared once the call returns")
    }

    /// A show is sent as its *own* id, never as an expanded list of episodes
    /// — Jellyfin expands a folder-shaped item server-side, and enumerating
    /// episodes here would both duplicate that work and get it wrong for a
    /// show whose episodes this client hasn't fetched.
    func test_add_showTarget_sendsTheSeriesIDNotItsEpisodes() async throws {
        let viewModel = makeViewModel(
            target: item("series-1", name: "Northern Lights", type: .series, episodeCount: 42)
        )
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        try await viewModel.add(to: "pl-mine")

        XCTAssertEqual(MockURLProtocol.lastRequest?.queryDictionary["ids"], "series-1")
    }

    func test_add_serverRefusal_rethrowsAndClearsSubmitting() async {
        let viewModel = makeViewModel(target: item("movie-1"))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 403, body: Data())
        }

        do {
            try await viewModel.add(to: "pl-mine")
            XCTFail("Expected .notPermitted")
        } catch JellyfinAPIError.notPermitted {
            // expected
        } catch {
            XCTFail("Expected .notPermitted, got \(error)")
        }
        XCTAssertFalse(viewModel.isSubmitting)
    }

    // MARK: - Creating

    func test_create_sendsTrimmedNameSeededWithTheTarget() async throws {
        let viewModel = makeViewModel(target: item("movie-3"))
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request, value: PlaylistCreationResult(id: "pl-new")
            )
        }

        try await viewModel.create(named: "  Weeknights  ", isPublic: false)

        let request = MockURLProtocol.lastRequest
        XCTAssertEqual(request?.url?.path, "/Playlists")
        let body = try XCTUnwrap(request?.capturedHTTPBody)
        let decoded = try JellyfinJSON.decoder.decode(CreatePlaylistRequest.self, from: body)
        XCTAssertEqual(decoded.name, "Weeknights")
        XCTAssertEqual(decoded.ids, ["movie-3"])
        XCTAssertEqual(decoded.isPublic, false)
    }

    func test_create_passesTheVisibilityChoiceThrough() async throws {
        let viewModel = makeViewModel(target: item("movie-3"))
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request, value: PlaylistCreationResult(id: "pl-new")
            )
        }

        try await viewModel.create(named: "Shared", isPublic: true)

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.capturedHTTPBody)
        let decoded = try JellyfinJSON.decoder.decode(CreatePlaylistRequest.self, from: body)
        XCTAssertEqual(decoded.isPublic, true)
    }

    // MARK: - Confirmation rules

    /// The rule that decides whether tapping an existing playlist stops to
    /// ask. Single items don't; folder-shaped targets, which expand into
    /// every episode beneath them, do.
    func test_requiresConfirmation_onlyForShowsAndSeasons() {
        XCTAssertFalse(makeViewModel(target: item("movie-1", type: .movie)).requiresConfirmation)
        XCTAssertFalse(makeViewModel(target: item("ep-1", type: .episode)).requiresConfirmation)
        XCTAssertTrue(makeViewModel(target: item("series-1", type: .series)).requiresConfirmation)
        XCTAssertTrue(makeViewModel(target: item("season-1", type: .season)).requiresConfirmation)
    }

    /// The confirmation's action button says how many things it will add.
    func test_addActionTitle_namesTheCountForAShowAndStaysPlainForASingleItem() async {
        XCTAssertEqual(makeViewModel(target: item("movie-1")).addActionTitle, "Add")

        let show = makeViewModel(target: item("series-1", type: .series))
        installLoadHandler(
            browse: [], canEditByPlaylistID: [:],
            seriesEpisodes: (1...5).map { item("ep-\($0)").dto }
        )
        await show.load()

        XCTAssertEqual(show.addActionTitle, "Add 5 Episodes")
    }

    /// With no resolved episode list *and* no server count, the button says
    /// what it will do without inventing a number.
    func test_addActionTitle_fallsBackWhenTheCountIsUnknown() {
        let show = makeViewModel(target: item("series-1", type: .series))
        XCTAssertEqual(show.addActionTitle, "Add All Episodes")
    }

    /// The resolved episode list is preferred over the server's
    /// `recursiveItemCount`: it's the exact set of ids the add will expand
    /// into, where the count is only present if something asked for it.
    func test_expandedItemCount_prefersTheResolvedEpisodeListOverRecursiveItemCount() async {
        let show = makeViewModel(target: item("series-1", type: .series, episodeCount: 99))
        installLoadHandler(
            browse: [], canEditByPlaylistID: [:],
            seriesEpisodes: (1...4).map { item("ep-\($0)").dto }
        )
        await show.load()

        XCTAssertEqual(show.expandedItemCount, 4)
    }

    func test_toastCopy_namesTheDestinationAndScalesWithTheTarget() async {
        let movie = makeViewModel(target: item("movie-1", name: "Arrival"))
        XCTAssertEqual(
            movie.addedToastMessage(playlistName: "Weeknights"),
            "Added to \"Weeknights\""
        )
        XCTAssertTrue(movie.createdToastMessage(playlistName: "Weeknights").contains("Weeknights"))

        let show = makeViewModel(target: item("series-1", type: .series))
        installLoadHandler(
            browse: [], canEditByPlaylistID: [:],
            seriesEpisodes: (1...3).map { item("ep-\($0)").dto }
        )
        await show.load()

        XCTAssertEqual(
            show.addedToastMessage(playlistName: "Weeknights"),
            "Added 3 episodes to \"Weeknights\""
        )
    }

    func test_expandedItemCount_readsRecursiveItemCountForShowsOnly() {
        XCTAssertEqual(
            makeViewModel(target: item("series-1", type: .series, episodeCount: 42)).expandedItemCount, 42
        )
        // A movie has no expansion to count, whatever the server sent.
        XCTAssertNil(
            makeViewModel(target: item("movie-1", type: .movie, episodeCount: 42)).expandedItemCount
        )
        // Absent or zero counts fall back to the count-free copy rather than
        // claiming "0 episodes".
        XCTAssertNil(makeViewModel(target: item("series-2", type: .series)).expandedItemCount)
        XCTAssertNil(
            makeViewModel(target: item("series-3", type: .series, episodeCount: 0)).expandedItemCount
        )
    }

    func test_confirmationCopy_namesTheCountAndPlaylistWhenKnown() {
        let show = makeViewModel(target: item("series-1", name: "Northern Lights", type: .series, episodeCount: 42))
        XCTAssertTrue(
            show.addConfirmationMessage(playlistName: "Weekend Watchlist").contains("42"),
            "Expected the episode count in: \(show.addConfirmationMessage(playlistName: "Weekend Watchlist"))"
        )
        XCTAssertTrue(show.addConfirmationMessage(playlistName: "Weekend Watchlist").contains("Weekend Watchlist"))

        let unknownCount = makeViewModel(target: item("series-2", type: .series))
        let message = unknownCount.addConfirmationMessage(playlistName: "Weekend Watchlist")
        XCTAssertFalse(message.contains("0"), "Must not claim a count it doesn't have: \(message)")
    }

    /// Creating always confirms, including for a single movie — so this copy
    /// has to name the item rather than an episode count.
    func test_createConfirmationCopy_namesTheItemForASingleTarget() {
        let movie = makeViewModel(target: item("movie-1", name: "Arrival", type: .movie))
        let message = movie.createConfirmationMessage(playlistName: "Weeknights")
        XCTAssertTrue(message.contains("Arrival"), "Expected the item name in: \(message)")
        XCTAssertTrue(message.contains("Weeknights"), "Expected the playlist name in: \(message)")
    }
}
