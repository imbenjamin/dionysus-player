import Foundation

/// Thin async/await REST client for the Jellyfin endpoints this app needs
/// (https://api.jellyfin.org/).
///
/// Hand-written against the documented HTTP/JSON API rather than a generated
/// SDK, so the surface is deliberately small: server setup, sign-in, browsing,
/// search, and playback.
actor JellyfinAPIClient {
    private(set) var baseURL: URL
    private(set) var accessToken: String?
    private let session: URLSession

    /// The URL the most recent response came back from. `URLSession` follows
    /// redirects transparently, so this can differ from the request's own URL
    /// without callers seeing one. `ServerSetupViewModel.testConnection()` reads
    /// it to correct a configured scheme — a later `POST` is not
    /// redirect-safe the way that GET-based ping is.
    private(set) var lastResponseURL: URL?

    /// The credentials that last succeeded via `authenticate(...)`, kept so a
    /// mid-session 401 can re-authenticate and retry rather than surfacing an
    /// error. A server can invalidate a session token with no action by this
    /// app. `nil` before sign-in, cleared by `forgetReauthCredentials()`.
    private var reauthCredentials: (username: String, password: String)?
    /// Coalesces concurrent re-authentications into one `Task`: a fan-out like
    /// `HomeViewModel.load()` can 401 several times at once, and each racing
    /// independently would spam `/Users/AuthenticateByName`. Check-then-set
    /// needs no lock — actor-isolated state, and neither line suspends.
    private var inFlightReauth: Task<Void, Error>?
    /// Delays before each re-authentication attempt after a 401; the first is
    /// immediate, so index 0 precedes the second attempt. Bounded so a revoked
    /// credential surfaces `.notAuthenticated` and returns the user to login.
    private static let reauthBackoffSchedule: [Double] = [0.5, 1.0, 2.0, 4.0]

    init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    /// Called on sign-out. `AppState` reuses this client across a
    /// sign-out/sign-back-in on the same server, so without this a request
    /// still in flight could re-authenticate as the previous user.
    func forgetReauthCredentials() {
        reauthCredentials = nil
    }

    // MARK: - System

    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    /// Jellyfin's liveness endpoint — plain "Healthy" text, not JSON — used for
    /// connectivity probes instead of `publicSystemInfo()`, which decodes a
    /// full payload to prove reachability. Unauthenticated. Callers discard the
    /// result; the point is `sendRaw`'s side effect on `ConnectivityMonitor`.
    func healthCheck() async throws {
        let request = try makeRequest(path: "/health", method: "GET")
        _ = try await sendRaw(request)
    }

    // MARK: - Auth

    @discardableResult
    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        let body = AuthenticateByNameRequest(username: username, pw: password)
        let result: AuthenticationResult = try await post("/Users/AuthenticateByName", body: body, requiresAuth: false)
        accessToken = result.accessToken
        // For `sendRaw`'s 401 auto-retry. Only on success, so a failed sign-in
        // never overwrites a still-good credential with a broken one.
        reauthCredentials = (username, password)
        return result
    }

    /// Hydrates this client from cached credentials with no network round-trip,
    /// for a launch where the server is unreachable but `ServerSessionStore`
    /// holds a token. Sets the same state as a successful `authenticate(...)`,
    /// so `sendRaw`'s 401 retry works once connectivity returns.
    func restoreSession(accessToken: String, username: String, password: String) {
        self.accessToken = accessToken
        reauthCredentials = (username, password)
    }

    // MARK: - Browsing

    // `Genres`/`Studios` must be named explicitly or the server omits them;
    // `CollectionGridView`'s filters need both.
    private static let defaultFields = "Overview,Genres,Studios,PrimaryImageAspectRatio,BasicSyncInfo"
    /// Non-`private` so `episodes(seriesID:seasonID:userID:fields:)` callers can
    /// opt into this heavier list.
    ///
    /// `Chapters` is included rather than opt-in like `Trickplay`: it is cheap
    /// metadata already in the item's row, and both consumers need it —
    /// `AssetDetailViewModel` for the Chapters rail and `PlayerViewModel.start()`
    /// for the chapter scrubber.
    ///
    /// `CanDelete` and `RecursiveItemCount` stay out of `defaultFields` because
    /// `CanDelete` costs a per-item collection-folder lookup that a rail of
    /// dozens of items shouldn't pay. A preloaded `MediaItem` therefore carries
    /// `canDelete == nil` until the detail fetch lands, which
    /// `MediaItem.canDelete` reads as `false` so the affordance appears late
    /// rather than wrongly.
    static let detailFields = "Overview,Genres,Studios,PrimaryImageAspectRatio,MediaSources,People,Taglines,Chapters,BasicSyncInfo,CanDelete,RecursiveItemCount"
    /// `detailFields` plus `Trickplay`, passed explicitly by the callers that
    /// need it (see `item(userID:itemID:fields:)`).
    static let detailFieldsWithTrickplay = detailFields + ",Trickplay"

    func userViews(userID: String) async throws -> BaseItemDtoQueryResult {
        try await get("/Users/\(userID)/Views")
    }

    // AUDIO SUPPRESSION: the audio/music `BaseItemKind` raw values Dionysus
    // Player can't play yet, for callers to pass as `items(...)`'s or
    // `resumeItems(...)`'s `excludeItemTypes:` — see `BaseItemDto
    // .isAudioContent` (`JellyfinModels.swift`) for the reasoning behind
    // this exact set (`Playlist` isn't included: an audio playlist can't be
    // excluded by type alone, since Jellyfin also uses `Playlist` for
    // mixed/video playlists — that case is instead caught client-side by
    // `isAudioContent`). Delete this constant and its two call sites once
    // Dionysus Player supports audio/music playback.
    static let audioItemTypeExclusions = ["Audio", "AudioBook", "MusicAlbum", "MusicArtist", "MusicGenre"]

    func items(
        userID: String,
        parentID: String? = nil,
        includeItemTypes: [String] = [],
        excludeItemTypes: [String] = [],
        mediaTypes: [String] = [],
        recursive: Bool = true,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        /// Jellyfin's `ItemFilter` values, e.g. `"IsUnplayed"`, `"IsFavorite"`
        /// — joined into a single comma-separated `Filters` query param.
        filters: [String] = [],
        /// Genre/studio names from `genres(...)`/`studios(...)`, joined with
        /// `"|"`. These two params are pipe-delimited while every other joined
        /// param here is comma-delimited — per `ItemsController`, not an
        /// oversight.
        genres: [String] = [],
        studios: [String] = [],
        /// One name — Jellyfin's `Person` param takes a single value, not a
        /// list. Pair with `personTypes` to narrow to a role; `personTypes`
        /// alone is ignored, so callers set both together.
        person: String? = nil,
        /// Comma-delimited, unlike `genres`/`studios` above.
        personTypes: [String] = [],
        searchTerm: String? = nil,
        limit: Int? = nil,
        /// Overridable so a caller needing only `id`/`name`/`type` can pass
        /// `""` and skip `defaultFields`' heavier payload; Jellyfin returns
        /// those three with no `Fields` param at all.
        fields: String = defaultFields
    ) async throws -> BaseItemDtoQueryResult {
        var query: [URLQueryItem] = [
            .init(name: "Recursive", value: String(recursive)),
            .init(name: "SortBy", value: sortBy),
            .init(name: "SortOrder", value: sortOrder)
        ]
        if !fields.isEmpty { query.append(.init(name: "Fields", value: fields)) }
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        if !excludeItemTypes.isEmpty {
            query.append(.init(name: "ExcludeItemTypes", value: excludeItemTypes.joined(separator: ",")))
        }
        if !mediaTypes.isEmpty {
            query.append(.init(name: "MediaTypes", value: mediaTypes.joined(separator: ",")))
        }
        if !filters.isEmpty { query.append(.init(name: "Filters", value: filters.joined(separator: ","))) }
        if !genres.isEmpty { query.append(.init(name: "Genres", value: genres.joined(separator: "|"))) }
        if !studios.isEmpty { query.append(.init(name: "Studios", value: studios.joined(separator: "|"))) }
        if let person, !person.isEmpty { query.append(.init(name: "Person", value: person)) }
        if !personTypes.isEmpty { query.append(.init(name: "PersonTypes", value: personTypes.joined(separator: ","))) }
        if let searchTerm, !searchTerm.isEmpty { query.append(.init(name: "SearchTerm", value: searchTerm)) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Users/\(userID)/Items", query: query)
    }

    /// Genres present in the library, scoped by content type. Jellyfin returns
    /// a genre only if something of that type has it, so this also serves as
    /// the existence check for Home's dynamic genre rails, with no per-genre
    /// count query.
    func genres(userID: String, includeItemTypes: [String]) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        return try await get("/Genres", query: query)
    }

    /// As `genres(...)`, for studios. Jellyfin has no separate Network concept —
    /// a show's network and a movie's studio share the `Studios` field — so the
    /// split for Home's "Movies from X"/"Shows from X" rails comes from
    /// `includeItemTypes`, not a different endpoint.
    func studios(userID: String, includeItemTypes: [String]) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        return try await get("/Studios", query: query)
    }

    /// People credited in the given roles anywhere in the library. `/Persons`
    /// has no `IncludeItemTypes`, so unlike genre and studio rails this cannot
    /// be scoped to movies versus shows.
    ///
    /// `limit` matters here where it doesn't for `genres(...)`/`studios(...)`:
    /// those return a few dozen values, but a library's cast and crew can run
    /// to thousands of full `BaseItemDto`s, fetched on every Home load to seed
    /// candidates most of which never clear
    /// `HomeViewModel.minimumDynamicRailItemCount`.
    func persons(userID: String, personTypes: [String], limit: Int? = nil) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !personTypes.isEmpty {
            query.append(.init(name: "personTypes", value: personTypes.joined(separator: ",")))
        }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Persons", query: query)
    }

    /// `fields` is overridable so a caller needing more than `detailFields` —
    /// `PlayerViewModel.start()` also wants `Trickplay` — can ask without
    /// widening the default. `AssetDetailViewModel` calls this from several
    /// sites, some of them polling loops, and none need trickplay.
    func item(userID: String, itemID: String, fields: String = detailFields) async throws -> BaseItemDto {
        try await get("/Users/\(userID)/Items/\(itemID)", query: [.init(name: "Fields", value: fields)])
    }

    func resumeItems(userID: String, limit: Int = 12, excludeItemTypes: [String] = []) async throws -> BaseItemDtoQueryResult {
        var query = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields)
        ]
        if !excludeItemTypes.isEmpty {
            query.append(.init(name: "ExcludeItemTypes", value: excludeItemTypes.joined(separator: ",")))
        }
        return try await get("/Users/\(userID)/Items/Resume", query: query)
    }

    func latestItems(userID: String, parentID: String? = nil, limit: Int = 16) async throws -> [BaseItemDto] {
        var query = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.defaultFields)
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        return try await get("/Users/\(userID)/Items/Latest", query: query)
    }

    // MARK: - Shows

    func seasons(seriesID: String, userID: String) async throws -> BaseItemDtoQueryResult {
        try await get("/Shows/\(seriesID)/Seasons", query: [.init(name: "userId", value: userID)])
    }

    /// `fields:` defaults to `defaultFields`, enough for
    /// `AssetDetailViewModel`'s "does this show have episodes" lookups. Pass
    /// `detailFields` when `People` is needed: `SeasonEpisodeList` does, because
    /// its `episodes` array also backs `DownloadButton`'s `enqueue(item:...)`,
    /// and an episode download's offline Cast & Crew comes from
    /// `item.dto.people`.
    ///
    /// Omitting `seasonID` returns every episode across all seasons, which is
    /// what `AddToPlaylistViewModel.load()` needs to know what "add the whole
    /// show" would add.
    func episodes(
        seriesID: String, seasonID: String? = nil, userID: String, fields: String = defaultFields
    ) async throws -> BaseItemDtoQueryResult {
        var query: [URLQueryItem] = [
            .init(name: "userId", value: userID),
            .init(name: "Fields", value: fields)
        ]
        if let seasonID { query.insert(.init(name: "seasonId", value: seasonID), at: 0) }
        return try await get("/Shows/\(seriesID)/Episodes", query: query)
    }

    /// Without `seriesID`, next-up episodes across every show the user is
    /// watching — Home's "Next Up" rail. With it, just that series, which is how
    /// `AssetDetailViewModel.resolveShowPlaybackEpisode` finds a Series page's
    /// Play/Resume target; that caller reads only the first result, so `limit`
    /// and `fields` stay optional.
    func nextUp(userID: String, seriesID: String? = nil, limit: Int? = nil) async throws -> BaseItemDtoQueryResult {
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Fields", value: Self.defaultFields)
        ]
        if let seriesID { query.append(.init(name: "SeriesId", value: seriesID)) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Shows/NextUp", query: query)
    }

    /// The episode following `currentEpisodeID`, regardless of watched state.
    /// `nextUp(userID:seriesID:)` keeps returning the current episode until the
    /// server confirms it `played`, which is too slow for `PlayerViewModel`'s
    /// in-player "Up Next" countdown.
    ///
    /// Sorts the current season by `indexNumber` and returns what follows. If
    /// that episode is last, or absent from the list, falls through to the next
    /// season's first episode. `nil` once the series has finished.
    func nextEpisode(currentEpisodeID: String, seriesID: String, seasonID: String, userID: String) async throws -> BaseItemDto? {
        let currentSeasonEpisodes = try await episodes(seriesID: seriesID, seasonID: seasonID, userID: userID).items
            .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        if let currentIndex = currentSeasonEpisodes.firstIndex(where: { $0.id == currentEpisodeID }),
           currentIndex + 1 < currentSeasonEpisodes.count {
            return currentSeasonEpisodes[currentIndex + 1]
        }

        let allSeasons = try await seasons(seriesID: seriesID, userID: userID).items
            .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        guard let currentSeasonIndex = allSeasons.firstIndex(where: { $0.id == seasonID }),
              currentSeasonIndex + 1 < allSeasons.count else { return nil }
        let nextSeason = allSeasons[currentSeasonIndex + 1]

        return try await episodes(seriesID: seriesID, seasonID: nextSeason.id, userID: userID).items
            .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            .first
    }

    // MARK: - Playlists

    /// A playlist's members in its authored order. The endpoint takes no
    /// `SortBy`: Jellyfin returns the stored order, which is what
    /// `PlaylistDetailView`'s play-through button and Up Next queueing need.
    ///
    /// `userId` is passed defensively — jellyfin/jellyfin#15600 reports this
    /// endpoint 400ing without it under API-key auth.
    func playlistItems(playlistID: String, userID: String, fields: String = defaultFields) async throws -> BaseItemDtoQueryResult {
        try await get("/Playlists/\(playlistID)/Items", query: [
            .init(name: "userId", value: userID),
            .init(name: "Fields", value: fields)
        ])
    }

    /// Whether this user may edit this playlist — the playlist equivalent of
    /// `BaseItemDto.canDelete`, and likewise answered by the server rather than
    /// derived from policy flags. The mutating endpoints gate on
    /// `OwnerUserId == caller || Shares.Any(CanEdit && caller)`, and
    /// `OwnerUserId` appears in no readable DTO, so there is no field to
    /// request. Self-querying this endpoint is how jellyfin-web resolves it
    /// (`itemHelper.js`'s `canEditPlaylist`).
    ///
    /// An owner gets `canEdit: true`, a share its real value, anyone else a
    /// 404, mapped to `nil`: a missing permissions record means no permission,
    /// not a failed request. A 403 maps to `nil` too — a self-query can't
    /// produce one, but `editablePlaylists(userID:)`' fan-out must not be
    /// derailed by an unexpected refusal.
    func playlistUserPermissions(playlistID: String, userID: String) async throws -> PlaylistUserPermissions? {
        do {
            return try await get("/Playlists/\(playlistID)/Users/\(userID)")
        } catch JellyfinAPIError.http(status: 404, message: _) {
            return nil
        } catch JellyfinAPIError.http(status: 403, message: _) {
            return nil
        }
    }

    /// Every playlist this user may add items to, for the "Add to Playlist"
    /// picker.
    ///
    /// The same problem as `collectionsContaining` below: no bulk "which
    /// playlists can I edit" query and no `OwnerUserId` on any readable DTO, so
    /// the only answer is one `playlistUserPermissions` call per playlist.
    /// jellyfin-web does the same (`playlisteditor.ts`'s `populatePlaylists`),
    /// so the N+1 is inherent to the API.
    ///
    /// Concurrency is capped, and each check is fail-soft, so one flaky
    /// response reads as "not editable" rather than failing the picker. Only
    /// the initial browse can throw.
    ///
    /// Audio playlists are dropped before the fan-out: the app can't play them,
    /// so one would be a dead end as a destination, and skipping them early is
    /// also the cheapest way to shrink the fan-out on a music-heavy server.
    func editablePlaylists(userID: String) async throws -> [EditablePlaylist] {
        // The picker renders a name and nothing else. `MediaType`, which
        // `isAudioContent` reads, is always serialized and not one of the
        // `ItemFields` extras this parameter controls.
        let playlists = try await items(
            userID: userID, includeItemTypes: ["Playlist"], sortBy: "SortName", fields: ""
        ).items.filter { !$0.isAudioContent }
        guard !playlists.isEmpty else { return [] }

        let maxConcurrency = 5
        return await withTaskGroup(of: EditablePlaylist?.self) { group in
            var remaining = playlists[...]
            var editable: [EditablePlaylist] = []

            func addNext() {
                guard let playlist = remaining.popFirst() else { return }
                group.addTask {
                    // Two distinct ways to be "not editable" collapse into
                    // the same `nil` here, which is the intent: the request
                    // failed (`try?`), or it succeeded and the server has no
                    // permissions record for this user
                    // (`playlistUserPermissions`' own `nil`). Swift flattens
                    // `try?` over an already-optional result, so this is a
                    // single optional rather than a nested one.
                    guard let permissions = try? await self.playlistUserPermissions(
                        playlistID: playlist.id, userID: userID
                    ), permissions.canEdit else { return nil }
                    // Membership fails *open* — an empty set on a failed
                    // request leaves the row enabled. This only drives
                    // whether the picker greys a row out as "already
                    // added", so a lost request should cost the user a
                    // possible duplicate, never the ability to add at all.
                    let memberIDs = (try? await self.playlistMemberIDs(playlistID: playlist.id)) ?? []
                    return EditablePlaylist(item: playlist, memberItemIDs: memberIDs)
                }
            }

            for _ in 0..<min(maxConcurrency, playlists.count) { addNext() }
            while let result = await group.next() {
                if let result { editable.append(result) }
                addNext()
            }
            // Re-ordered against the original array rather than returned as
            // accumulated: the task group yields in *completion* order, so
            // the picker's rows would otherwise shuffle between openings
            // instead of holding the `SortName` order the browse asked for.
            let byID = Dictionary(editable.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
            return playlists.compactMap { byID[$0.id] }
        }
    }

    /// Which items a playlist already holds, for the picker's "already
    /// added" state.
    ///
    /// `GET /Playlists/{id}` is a different endpoint from
    /// `playlistItems(playlistID:userID:)` above and deliberately used here
    /// instead: it returns Jellyfin's `PlaylistDto` — bare item ids and
    /// nothing else — where the other returns fully hydrated `BaseItemDto`s
    /// with artwork, user data and media sources, all of which this call
    /// would immediately discard. That difference matters because this runs
    /// once per editable playlist.
    func playlistMemberIDs(playlistID: String) async throws -> Set<String> {
        let dto: PlaylistDto = try await get("/Playlists/\(playlistID)")
        return Set(dto.itemIds ?? [])
    }

    /// Adds one or more items to an existing playlist.
    ///
    /// `itemIDs` are ordinary item ids, unlike `removePlaylistItems`' entry
    /// ids — an item that isn't in the playlist yet has no `PlaylistItemId`
    /// to name it by.
    ///
    /// Passing a Series or Season id adds every episode beneath it in one
    /// request: `Playlist.GetPlaylistItems` expands folder-shaped items
    /// recursively server-side. Never enumerate episodes client-side for this.
    ///
    /// Refused with a clean 403, remapped as in `removePlaylistItems`.
    func addItemsToPlaylist(playlistID: String, itemIDs: [String], userID: String) async throws {
        do {
            try await sendNoContent(path: "/Playlists/\(playlistID)/Items", method: "POST", query: [
                .init(name: "ids", value: itemIDs.joined(separator: ",")),
                .init(name: "userId", value: userID)
            ])
        } catch JellyfinAPIError.http(status: 403, message: _) {
            throw JellyfinAPIError.notPermitted
        }
    }

    /// Creates a playlist, optionally seeded with items in the same request, so
    /// no create-then-add round trip is needed.
    ///
    /// Alone among the playlist calls here, this has no permission gate:
    /// `POST /Playlists` is `[Authorize]`-only, and `UserPolicy`'s
    /// `EnableCollectionManagement` covers collections, not playlists. Every
    /// signed-in user can create one, which is why `AssetActionsButton` offers
    /// "Add to Playlist" unconditionally.
    ///
    /// `isPublic` is always sent: `CreatePlaylistDto.IsPublic` defaults to
    /// `true` server-side, so omitting it would publish every playlist this app
    /// creates to every user on the server.
    func createPlaylist(
        name: String, itemIDs: [String], userID: String, isPublic: Bool
    ) async throws -> PlaylistCreationResult {
        try await post("/Playlists", body: CreatePlaylistRequest(
            name: name, ids: itemIDs, userId: userID, isPublic: isPublic
        ))
    }

    /// Removes entries from a playlist. `entryIDs` are each entry's
    /// `PlaylistItemId`, not the underlying item's `id`, since one item can
    /// appear in a playlist more than once (see `BaseItemDto.playlistItemId`).
    ///
    /// Jellyfin refuses this with a clean 403 rather than `deleteItem`'s
    /// ambiguous 401, so it needs none of that method's reduced-reauth-budget
    /// handling and remaps straight to `.notPermitted`.
    func removePlaylistItems(playlistID: String, entryIDs: [String]) async throws {
        do {
            try await sendNoContent(path: "/Playlists/\(playlistID)/Items", method: "DELETE", query: [
                .init(name: "entryIds", value: entryIDs.joined(separator: ","))
            ])
        } catch JellyfinAPIError.http(status: 403, message: _) {
            throw JellyfinAPIError.notPermitted
        }
    }

    /// "More Like This" for a detail page.
    func similarItems(itemID: String, userID: String, limit: Int = 12) async throws -> BaseItemDtoQueryResult {
        try await get("/Items/\(itemID)/Similar", query: [
            .init(name: "userId", value: userID),
            .init(name: "limit", value: String(limit)),
            .init(name: "Fields", value: Self.defaultFields)
        ])
    }

    /// Jellyfin has no "which collections contain this item" lookup, so this
    /// fetches every BoxSet and checks each one's membership individually.
    ///
    /// Concurrency is capped rather than firing all `boxSets.count` checks at
    /// once, which on a server with a few dozen collections meant upwards of
    /// 100 concurrent requests for one "Included In" rail. Each check is also
    /// fail-soft, so a hiccup reads as "not a match" rather than failing the
    /// call and, through `load()`, the whole page. Only the initial BoxSets
    /// probe can throw, which `load()` treats as non-fatal.
    func collectionsContaining(itemID: String, userID: String) async throws -> [BaseItemDto] {
        let boxSets = try await items(userID: userID, includeItemTypes: ["BoxSet"], limit: 100).items
        guard !boxSets.isEmpty else { return [] }

        let maxConcurrency = 5
        return await withTaskGroup(of: BaseItemDto?.self) { group in
            var remaining = boxSets[...]
            var matches: [BaseItemDto] = []

            func addNext() {
                guard let boxSet = remaining.popFirst() else { return }
                group.addTask {
                    // Membership needs only each child's `id`; `defaultFields`
                    // would be fetched and discarded for every item in every
                    // collection.
                    guard let children = try? await self.items(
                        userID: userID, parentID: boxSet.id, recursive: false, fields: ""
                    ) else { return nil }
                    return children.items.contains(where: { $0.id == itemID }) ? boxSet : nil
                }
            }

            for _ in 0..<min(maxConcurrency, boxSets.count) { addNext() }
            while let result = await group.next() {
                if let result { matches.append(result) }
                addNext()
            }
            return matches
        }
    }

    // MARK: - Media Segments

    /// Skippable Intro/Outro/Recap/Preview/Commercial ranges (see
    /// `MediaSegmentType` for the server-version caveat). Unfiltered;
    /// `PlaybackSegment.init?(dto:)` drops `.unknown`-typed segments.
    func mediaSegments(itemID: String) async throws -> [MediaSegmentDto] {
        let result: MediaSegmentDtoQueryResult = try await get("/MediaSegments/\(itemID)")
        return result.items
    }

    // MARK: - Playback

    /// With `deviceProfile`/`maxStreamingBitrate`/`startTimeTicks` nil, this
    /// sends a non-negotiated request body. `PlayerViewModel` passes them only
    /// in `.allowTranscoding` mode (see `DeviceProfileBuilder`);
    /// `DownloadManager` never does, since downloads negotiate nothing and
    /// always transcode via `downloadStreamURL`.
    func playbackInfo(
        itemID: String, userID: String, mediaSourceID: String? = nil,
        deviceProfile: DeviceProfile? = nil, maxStreamingBitrate: Int? = nil, startTimeTicks: Int64? = nil
    ) async throws -> PlaybackInfoResponse {
        try await post("/Items/\(itemID)/PlaybackInfo", body: PlaybackInfoRequest(
            userId: userID, mediaSourceId: mediaSourceID,
            deviceProfile: deviceProfile, maxStreamingBitrate: maxStreamingBitrate, startTimeTicks: startTimeTicks,
            allowVideoStreamCopy: deviceProfile != nil ? true : nil,
            allowAudioStreamCopy: deviceProfile != nil ? true : nil
        ))
    }

    /// A direct-play stream URL, for content the device decodes natively.
    /// `PlayerViewModel` falls back to this whenever
    /// `MediaSourceInfo.transcodingUrl` is absent, in both streaming modes.
    func streamURL(itemID: String, mediaSourceID: String?, container: String?) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query = [URLQueryItem(name: "Static", value: "true")]
        if let mediaSourceID { query.append(.init(name: "MediaSourceId", value: mediaSourceID)) }
        if let container { query.append(.init(name: "Container", value: container)) }
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        query.append(.init(name: "DeviceId", value: DeviceIdentity.deviceID))
        components.queryItems = query
        return components.url
    }

    /// Resolves `MediaSourceInfo.transcodingUrl` — a root-relative path with
    /// DeviceId, api_key and PlaySessionId already in its query — against
    /// `baseURL`. Used in "Allow Transcoding" mode when the server rules out
    /// direct play.
    ///
    /// Not `URL(string:relativeTo:)`: RFC 3986 resolution treats a path
    /// starting with `/`, which `transcodingUrl` always does, as replacing the
    /// base URL's entire path. Against a server reverse-proxied under a subpath
    /// (`https://host/flix`) that drops `/flix` and 404s. So split the path
    /// from the query, append the path as `streamURL` does, and keep the query.
    func resolveTranscodingURL(_ transcodingPath: String) -> URL? {
        guard let parsed = URLComponents(string: transcodingPath) else { return nil }
        let relativePathComponent = parsed.path.hasPrefix("/") ? String(parsed.path.dropFirst()) : parsed.path
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(relativePathComponent), resolvingAgainstBaseURL: false
        ) else { return nil }
        components.percentEncodedQuery = parsed.percentEncodedQuery
        return components.url
    }

    /// A direct-fetch URL for an external subtitle stream (`isExternal == true`),
    /// built against Jellyfin's well-known route
    /// (`/Videos/{itemId}/{mediaSourceId}/Subtitles/{streamIndex}/Stream.{format}`)
    /// the way `streamURL` builds the video route.
    ///
    /// Not `MediaStream.deliveryUrl`: Jellyfin populates that only when
    /// `/PlaybackInfo` carried a `DeviceProfile` negotiating subtitle delivery,
    /// so it is nil for every external stream here. The token travels as an
    /// `ApiKey` query item because AetherEngine's side-demuxer fetches this
    /// itself, outside this actor and with no `Authorization` header.
    func subtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, codec: String?) -> URL? {
        let ext = Self.subtitleFileExtension(forCodec: codec)
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.\(ext)"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query: [URLQueryItem] = []
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// The extension Jellyfin's subtitle route needs to serve a sidecar
    /// byte-for-byte instead of converting it server-side. Unknown codecs fall
    /// back to "srt", the commonest external format, which Jellyfin serves
    /// something for rather than 404ing. Non-`private`: `DownloadManager` names
    /// downloaded sidecar files with it.
    static func subtitleFileExtension(forCodec codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass": return "ass"
        case "ssa": return "ssa"
        case "webvtt", "vtt": return "vtt"
        default: return "srt"
        }
    }

    /// True for bitmap subtitle formats (PGS, VobSub, DVB). AetherEngine renders
    /// these live, but they can't be downloaded: `subtitleURL` has no
    /// server-side OCR to convert them to text, and MP4 can't embed a bitmap
    /// track. Download callers must skip them rather than fall through
    /// `subtitleFileExtension(forCodec:)`'s `default: "srt"`, which would
    /// request a bitmap stream as a garbage `.srt`.
    static func isImageBasedSubtitleCodec(_ codec: String?) -> Bool {
        switch codec?.lowercased() {
        case "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub":
            return true
        default:
            return false
        }
    }

    /// A device-transcoded download URL: HEVC MP4, capped to
    /// `resolution`/`preset` and never above the source's own values (see
    /// `DownloadTranscodeCalculator.target`). Always `Static=false`, unlike
    /// `streamURL`, so even a source within the tier's bounds is re-muxed to
    /// MP4/AAC. Audio is always AAC-LC stereo regardless of the source layout.
    ///
    /// Video is re-encoded only when it must be: a source already satisfying
    /// the tier (`DownloadTranscodeTarget.videoStreamCopyEligible`) is copied
    /// into the output via `AllowVideoStreamCopy` rather than paying for a
    /// second generation of lossy encoding.
    ///
    /// Two details established by testing rather than from the API docs:
    ///
    /// 1. `VideoCodec` must list the source's own codec, which is why
    ///    `requestedVideoCodecs` can be `"hevc,h264"`. Jellyfin copies only a
    ///    stream whose codec the client asked for; requesting `hevc` alone
    ///    against an H.264 source declines the copy silently.
    /// 2. The caps are still sent on the copy path. Jellyfin ignores them when
    ///    it copies, and they are all that bounds a declined copy's fallback
    ///    transcode. Without them a 1280×720 source came back 416×234 at
    ///    343 Kbps.
    ///
    /// `ApiKey` travels as a query param because this URL goes to a plain
    /// `URLSessionDownloadTask` outside this actor's request pipeline.
    ///
    /// `playSessionId` is how `pingDownloadTranscode` finds this transcode job
    /// again. See `DOWNLOADS.md` for how the tiers and bitrates were chosen.
    func downloadStreamURL(
        itemID: String,
        mediaSourceID: String?,
        audioStreamIndex: Int?,
        resolution: DownloadResolution,
        preset: DownloadBitratePreset,
        isSourceHDR: Bool,
        sourceWidth: Int?,
        sourceHeight: Int?,
        sourceBitrate: Int?,
        sourceVideoCodec: String? = nil,
        playSessionId: String? = nil
    ) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/stream.mp4"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        let target = DownloadTranscodeCalculator.target(
            resolution: resolution,
            preset: preset,
            isSourceHDR: isSourceHDR,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceBitrate: sourceBitrate,
            sourceVideoCodec: sourceVideoCodec,
            videoBitrateLadder: DownloadQualityLadderStore().videoBitrate(resolution:preset:)
        )

        var query: [URLQueryItem] = [
            .init(name: "Static", value: "false"),
            .init(name: "Container", value: "mp4"),
            .init(name: "VideoCodec", value: target.requestedVideoCodecs.joined(separator: ",")),
            .init(name: "AudioCodec", value: "aac"),
            .init(name: "AudioBitrate", value: String(preset.audioBitrate)),
            .init(name: "MaxAudioChannels", value: "2"),
            // Sent even when a stream copy is expected: ignored on the copy
            // path, and the only bound on the fallback if the copy is declined.
            .init(name: "MaxWidth", value: String(target.maxWidth)),
            .init(name: "MaxHeight", value: String(target.maxHeight)),
            .init(name: "VideoBitrate", value: String(target.videoBitrate)),
            .init(name: "VideoProfile", value: target.videoProfile)
        ]
        if target.videoStreamCopyEligible {
            query.append(.init(name: "AllowVideoStreamCopy", value: "true"))
        }
        if let maxFramerate = target.maxFramerate {
            query.append(.init(name: "MaxFramerate", value: String(maxFramerate)))
        }
        if let mediaSourceID { query.append(.init(name: "MediaSourceId", value: mediaSourceID)) }
        if let audioStreamIndex { query.append(.init(name: "AudioStreamIndex", value: String(audioStreamIndex))) }
        if let playSessionId { query.append(.init(name: "PlaySessionId", value: playSessionId)) }
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        query.append(.init(name: "DeviceId", value: DeviceIdentity.deviceID))
        components.queryItems = query
        return components.url
    }

    /// The live session Jellyfin tracks for this device: server-reported play
    /// method and live transcode parameters, used by `PlaybackStatsOverlay`'s
    /// "Streaming" section and `DownloadManager`'s transcode-progress polling.
    /// Filtered by the `DeviceId` every request already sends in its
    /// `Authorization` header.
    ///
    /// A device keeps exactly one session row however many concurrent transcode
    /// requests it drives, so a caller with more than one active transcode
    /// cannot tell which job `transcodingInfo` reflects (see
    /// `DownloadManager.startTranscodeProgressPolling`).
    func currentSession(deviceID: String) async throws -> SessionInfoDto? {
        let sessions: [SessionInfoDto] = try await get("/Sessions", query: [.init(name: "DeviceId", value: deviceID)])
        return sessions.first
    }

    /// Snapshot of the current base URL/token for building image URLs
    /// synchronously outside the actor — see `ImageURLBuilder`.
    func makeImageURLBuilder() -> ImageURLBuilder {
        ImageURLBuilder(baseURL: baseURL, accessToken: accessToken)
    }

    // MARK: - Playback progress reporting

    /// `playSessionID` is non-nil only in "Allow Transcoding" mode, from
    /// `PlaybackInfoResponse.playSessionId`.
    func reportPlaybackStart(itemID: String, mediaSourceID: String? = nil, playSessionID: String? = nil) async throws {
        try await postNoContent(
            "/Sessions/Playing",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: 0, mediaSourceId: mediaSourceID, playSessionId: playSessionID)
        )
    }

    func reportPlaybackProgress(
        itemID: String, positionTicks: Int64, isPaused: Bool, mediaSourceID: String? = nil, playSessionID: String? = nil
    ) async throws {
        try await postNoContent(
            "/Sessions/Playing/Progress",
            body: PlaybackProgressRequest(
                itemId: itemID, positionTicks: positionTicks, isPaused: isPaused, mediaSourceId: mediaSourceID, playSessionId: playSessionID
            )
        )
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64, mediaSourceID: String? = nil, playSessionID: String? = nil) async throws {
        try await postNoContent(
            "/Sessions/Playing/Stopped",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: positionTicks, mediaSourceId: mediaSourceID, playSessionId: playSessionID)
        )
    }

    /// Keeps a download's server-side transcode job alive. Jellyfin arms a
    /// 10-second kill timer on a progressive transcode job as soon as
    /// `ActiveRequestCount` reaches zero — which a transient stall under
    /// concurrent-download CPU contention can cause — and only a ping on the
    /// same `PlaySessionId` refreshes it. Plain playback never needs this; a
    /// download's long-lived unattended transfer does.
    ///
    /// Uses `/Sessions/Playing/Ping`, not `/Sessions/Playing/Progress`. Per
    /// Jellyfin's source (`PlaystateController.PingPlaybackSession` →
    /// `ITranscodeManager.PingTranscodingJob`) this touches only the kill
    /// timer, with no session, `NowPlayingItem` or `UserData` interaction, so
    /// it cannot make a never-played download appear watched in Continue
    /// Watching (see `DOWNLOADS.md`). It takes only a `PlaySessionId`.
    func pingDownloadTranscode(playSessionId: String) async throws {
        try await sendNoContent(path: "/Sessions/Playing/Ping", method: "POST", query: [.init(name: "playSessionId", value: playSessionId)])
    }

    /// Sets a user's watched/resume state directly. `DownloadSyncManager` uses
    /// this rather than `reportPlaybackProgress`/`reportPlaybackStopped`, which
    /// assume a live `PlaySessionId` an offline-recorded position lacks. This
    /// endpoint has no active-session requirement, which is what posting an
    /// update days later needs.
    ///
    /// `lastPlayedDate` must be the real on-device moment
    /// (`DownloadedItem.lastPlayedAt`); see `UpdateUserDataRequest`.
    func updateUserData(itemID: String, userID: String, positionTicks: Int64, isPlayed: Bool, playedPercentage: Double, lastPlayedDate: Date? = nil) async throws {
        try await postNoContent(
            "/Users/\(userID)/Items/\(itemID)/UserData",
            body: UpdateUserDataRequest(
                playbackPositionTicks: positionTicks, played: isPlayed, playedPercentage: playedPercentage, lastPlayedDate: lastPlayedDate
            )
        )
    }

    // MARK: - Favorite / watched status

    /// `POST` to favorite, `DELETE` to unfavorite, Jellyfin's toggle shape with
    /// no request body either way.
    func setFavorite(_ isFavorite: Bool, itemID: String, userID: String) async throws {
        try await sendNoContent(path: "/Users/\(userID)/FavoriteItems/\(itemID)", method: isFavorite ? "POST" : "DELETE")
    }

    /// Watched status, with `setFavorite`'s toggle shape. Marking a Series or
    /// Season played cascades to every episode server-side; nothing client-side
    /// needs to fan it out.
    func setWatched(_ isWatched: Bool, itemID: String, userID: String) async throws {
        try await sendNoContent(path: "/Users/\(userID)/PlayedItems/\(itemID)", method: isWatched ? "POST" : "DELETE")
    }

    // MARK: - Deletion

    /// Deletes an item from the server, including the media file itself:
    /// `LibraryController.DeleteItem` passes `DeleteFileLocation = true`, so
    /// this is irreversible.
    ///
    /// `/Items/{id}` takes no `userId`, unlike the per-user `setFavorite`/
    /// `setWatched`. The auth header identifies the user and the server
    /// authorizes per item against the same predicate `BaseItemDto.canDelete`
    /// reports, which is what the UI gates on.
    ///
    /// `maxReauthAttempts: 1` is load-bearing. Jellyfin reports "you may not
    /// delete this" as a 401, indistinguishable from an expired token, so the
    /// default budget would re-sign-in four times over ~7.5s and then bounce
    /// the user to the login screen for pressing a button they weren't allowed
    /// to press. One attempt still recovers a stale token; a 401 surviving it
    /// surfaces as `.notPermitted`.
    func deleteItem(itemID: String) async throws {
        try await sendNoContent(path: "/Items/\(itemID)", method: "DELETE", maxReauthAttempts: 1)
    }

    // MARK: - Search

    /// Jellyfin's `/Search/Hints`, `SearchView`'s sole source of results — a
    /// lighter lookup than the general-purpose `items(...)`. `includeItemTypes`
    /// is comma-delimited, as in `items(...)`.
    func searchHints(userID: String, term: String, limit: Int = 50) async throws -> SearchHintResult {
        try await get("/Search/Hints", query: [
            .init(name: "searchTerm", value: term),
            .init(name: "userId", value: userID),
            .init(name: "limit", value: String(limit)),
            .init(name: "includeItemTypes", value: "Movie,Series,Episode,BoxSet")
        ])
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", query: query)
        return try await send(request)
    }

    private func post<T: Decodable>(_ path: String, body: Encodable, requiresAuth: Bool = true) async throws -> T {
        let request = try makeRequest(path: path, method: "POST", body: body, requiresAuth: requiresAuth)
        return try await send(request)
    }

    private func postNoContent(_ path: String, body: Encodable) async throws {
        let request = try makeRequest(path: path, method: "POST", body: body)
        _ = try await sendRaw(request)
    }

    /// `postNoContent` for endpoints that also need no request body: the
    /// `setFavorite`/`setWatched` toggles and `pingDownloadTranscode`'s
    /// query-only ping. Adds a `method` and an optional `query`.
    ///
    /// `maxReauthAttempts` is forwarded to `sendRaw`; `nil` keeps the full
    /// backoff schedule.
    private func sendNoContent(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        maxReauthAttempts: Int? = nil
    ) async throws {
        let request = try makeRequest(path: path, method: method, query: query)
        _ = try await sendRaw(request, maxReauthAttempts: maxReauthAttempts)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        requiresAuth: Bool = true
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw JellyfinAPIError.invalidServerAddress
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw JellyfinAPIError.invalidServerAddress }

        var request = URLRequest(url: url)
        request.httpMethod = method
        // Never cached: item endpoints carry fast-moving user state (resume
        // position, played %), and `useProtocolCachePolicy` let the detail page
        // show stale progress after playback.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Per-request override of `.shared`'s 60s default.
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Jellyfin 12.0 disables the legacy `X-Emby-Authorization`/
        // `X-Emby-Token` headers by default, 400ing a request carrying only
        // those. `Authorization` with the `MediaBrowser` scheme is the
        // non-deprecated form and is accepted by 10.x too, so it is sent
        // unconditionally rather than branching on server version.
        request.setValue(
            JellyfinAuthorization.headerValue(token: requiresAuth ? accessToken : nil),
            forHTTPHeaderField: "Authorization"
        )

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JellyfinJSON.encoder.encode(body)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try JellyfinJSON.decoder.decode(T.self, from: data)
        } catch {
            throw JellyfinAPIError.decoding(error)
        }
    }

    /// `.shared`'s 60s default is too slow for offline detection: when a network
    /// path exists but can't route to a LAN-only server, the OS attempts a real
    /// connection and gives up only after the full timeout, which reads as the
    /// launch splash hanging rather than a prompt "you're offline".
    ///
    /// Applied via `URLRequest.timeoutInterval` in `makeRequest`, which
    /// `URLSession` honors whichever session dispatches the request. A session
    /// with a shorter `timeoutIntervalForRequest` would not work here: tests
    /// that build a `JellyfinAPIClient` internally rely on
    /// `URLProtocol.registerClass` hooking `.shared`, which a freshly
    /// constructed session doesn't pick up.
    ///
    /// Matches `RemoteImageLoader`'s 20s — short enough to fail fast, long
    /// enough not to misfire on a slow local server.
    private static let requestTimeout: TimeInterval = 20

    @discardableResult
    private func sendRaw(_ request: URLRequest, maxReauthAttempts: Int? = nil) async throws -> Data {
        try await sendRaw(request, reauthAttempt: 0, maxReauthAttempts: maxReauthAttempts ?? Self.reauthBackoffSchedule.count)
    }

    /// `reauthAttempt` counts this logical request's re-authentications so far,
    /// bounding the recursion against `maxReauthAttempts` and selecting the
    /// backoff delay.
    ///
    /// `maxReauthAttempts` defaults to the full `reauthBackoffSchedule`. A
    /// caller whose endpoint answers permission-denied with 401 rather than 403
    /// — `DELETE /Items/{id}` today — passes a smaller budget so a real
    /// permission failure reports `.notPermitted` promptly instead of being
    /// retried as an expired token and surfacing as `.notAuthenticated`. One
    /// attempt remains, so a genuinely expired token still recovers.
    private func sendRaw(_ request: URLRequest, reauthAttempt: Int, maxReauthAttempts: Int) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.indicatesOffline {
            await ConnectivityMonitor.shared.reportFailure()
            throw urlError
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinAPIError.invalidResponse }
        lastResponseURL = response.url
        // Any HTTP response, success or error, proves the server reachable.
        await ConnectivityMonitor.shared.reportSuccess()
        guard (200..<300).contains(http.statusCode) else {
            // Only `requiresAuth: true` with an existing `accessToken` puts a
            // `Token="…"` clause in the header. `authenticate(...)`'s own 401 —
            // a wrong password at first sign-in — is sent with
            // `requiresAuth: false`, so it skips both branches below and keeps
            // its raw `.http(401, ...)`.
            let isTokenBearing401 = http.statusCode == 401
                && (request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"") ?? false)
            guard isTokenBearing401 else {
                throw JellyfinAPIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8))
            }

            // A token-bearing 401 doesn't mean the credentials are bad: a
            // server can invalidate a session token on its own. Re-authenticate
            // with the last-successful credentials and retry before giving up.
            if let reauthCredentials, reauthAttempt < maxReauthAttempts {
                do {
                    try await reauthenticate(using: reauthCredentials, attempt: reauthAttempt)
                } catch {
                    // Re-authentication itself failed. Fall through to
                    // `.notAuthenticated` rather than reporting "couldn't reach
                    // the server" for what the user experiences as a logout.
                    throw JellyfinAPIError.notAuthenticated
                }
                var retried = request
                retried.setValue(JellyfinAuthorization.headerValue(token: accessToken), forHTTPHeaderField: "Authorization")
                return try await sendRaw(retried, reauthAttempt: reauthAttempt + 1, maxReauthAttempts: maxReauthAttempts)
            }

            // A reduced reauth budget means this endpoint uses 401 for "not
            // allowed" too. Re-authentication succeeded and the request was
            // still refused, so the credentials are fine and this is a
            // permission failure, not a session problem.
            if maxReauthAttempts < Self.reauthBackoffSchedule.count, reauthAttempt > 0 {
                throw JellyfinAPIError.notPermitted
            }

            // Nothing left to retry with. A raw `.http(401, ...)` would surface
            // Jellyfin's default 401 body, a full branded HTML document.
            throw JellyfinAPIError.notAuthenticated
        }
        return data
    }

    /// Coalesces concurrent re-authentications into one `Task` (see
    /// `inFlightReauth`). `attempt` selects the backoff delay, skipped at
    /// `attempt == 0` so a one-off 401 recovers immediately.
    private func reauthenticate(using credentials: (username: String, password: String), attempt: Int) async throws {
        if let inFlightReauth {
            try await inFlightReauth.value
            return
        }
        let task = Task<Void, Error> {
            if attempt > 0 {
                let delay = Self.reauthBackoffSchedule[min(attempt, Self.reauthBackoffSchedule.count) - 1]
                try await Task.sleep(for: .seconds(delay))
            }
            try await self.authenticate(username: credentials.username, password: credentials.password)
        }
        inFlightReauth = task
        defer { inFlightReauth = nil }
        try await task.value
    }
}
