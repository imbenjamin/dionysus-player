import Foundation

/// Thin async/await REST client for the endpoints Dionysus Player needs,
/// following the public Jellyfin API (https://api.jellyfin.org/).
///
/// This talks to the documented HTTP/JSON API directly rather than depending
/// on a generated SDK, so the surface here is intentionally small: just
/// enough for server setup, sign-in, browsing, search, and basic playback
/// (direct play, no transcode/device-profile negotiation yet).
actor JellyfinAPIClient {
    private(set) var baseURL: URL
    private(set) var accessToken: String?
    private let session: URLSession

    init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: - System

    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    /// Jellyfin's lightweight, purpose-built liveness endpoint (`GET
    /// /health` — plain "Healthy" text, not JSON) — used for the app's own
    /// connectivity probes (see `DionysusPlayerApp`'s scenePhase-driven
    /// resume check) rather than `publicSystemInfo()` above, which fetches
    /// and JSON-decodes a full payload just to prove reachability.
    /// Unauthenticated, same as `publicSystemInfo()`. The result is
    /// discarded by callers — the point is `sendRaw`'s side effect on
    /// `ConnectivityMonitor`, not anything in the response body.
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
        return result
    }

    // MARK: - Browsing

    // `Studios` added for CollectionGridView's Studios filter — without it
    // in `Fields`, the server omits `BaseItemDto.studios` entirely (same
    // reason `Genres` is already listed here rather than assumed default).
    private static let defaultFields = "Overview,Genres,Studios,PrimaryImageAspectRatio,BasicSyncInfo"
    private static let detailFields = "Overview,Genres,Studios,PrimaryImageAspectRatio,MediaSources,People,Taglines,BasicSyncInfo"
    /// `detailFields` plus `Trickplay` — `PlayerViewModel.start()`'s own
    /// item fetch passes this explicitly (see `item(userID:itemID:fields:)`'s
    /// doc comment for why `detailFields` itself doesn't carry this).
    static let detailFieldsWithTrickplay = detailFields + ",Trickplay"

    func userViews(userID: String) async throws -> BaseItemDtoQueryResult {
        try await get("/Users/\(userID)/Views")
    }

    func items(
        userID: String,
        parentID: String? = nil,
        includeItemTypes: [String] = [],
        recursive: Bool = true,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        /// Jellyfin's `ItemFilter` values, e.g. `"IsUnplayed"`, `"IsFavorite"`
        /// — joined into a single comma-separated `Filters` query param.
        filters: [String] = [],
        /// Genre/studio *names* (as returned by `genres(...)`/`studios(...)`
        /// below), joined with `"|"` — Jellyfin's `Genres`/`Studios` params
        /// are pipe-delimited, unlike every other joined param on this
        /// method (`IncludeItemTypes`/`Filters` are comma-delimited). Don't
        /// "fix" this to match those by pattern-matching the rest of the
        /// method — it's pipe on purpose, confirmed against the real
        /// `ItemsController` signature.
        genres: [String] = [],
        studios: [String] = [],
        /// A single person's *name* (Jellyfin's `Person` param takes one
        /// name, not a delimited list) — pair with `personTypes` to narrow
        /// to a specific role, e.g. `person: "Tom Hanks", personTypes:
        /// ["Actor"]`. `personTypes` alone (no `person`) isn't meaningful
        /// and is ignored by Jellyfin, so callers always set both together.
        person: String? = nil,
        /// Comma-delimited, unlike `genres`/`studios` above — confirmed
        /// against the real `ItemsController` signature.
        personTypes: [String] = [],
        searchTerm: String? = nil,
        limit: Int? = nil,
        /// Overridable so a caller that only needs `id`/`name`/`type` (e.g.
        /// `collectionsContaining`'s per-collection membership check) can
        /// pass `""` to skip `defaultFields`' heavier payload
        /// (Overview/Genres/Studios/...) entirely rather than paying for
        /// data it's just going to throw away — Jellyfin already returns
        /// those three fields with no `Fields` param at all. Every existing
        /// caller keeps getting `defaultFields` unchanged since it's the
        /// default here too.
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
        if !filters.isEmpty { query.append(.init(name: "Filters", value: filters.joined(separator: ","))) }
        if !genres.isEmpty { query.append(.init(name: "Genres", value: genres.joined(separator: "|"))) }
        if !studios.isEmpty { query.append(.init(name: "Studios", value: studios.joined(separator: "|"))) }
        if let person, !person.isEmpty { query.append(.init(name: "Person", value: person)) }
        if !personTypes.isEmpty { query.append(.init(name: "PersonTypes", value: personTypes.joined(separator: ","))) }
        if let searchTerm, !searchTerm.isEmpty { query.append(.init(name: "SearchTerm", value: searchTerm)) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Users/\(userID)/Items", query: query)
    }

    /// Genres actually present in the user's library, scoped by content
    /// type (`includeItemTypes: ["Movie"]` vs `["Series"]`) — Jellyfin only
    /// returns a genre here if something of that type actually has it, so
    /// this doubles as existence-checking for Home's dynamic genre rails
    /// (`HomeViewModel.loadDynamicRailCandidates`) without a separate
    /// per-genre count query.
    func genres(userID: String, includeItemTypes: [String]) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        return try await get("/Genres", query: query)
    }

    /// Same as `genres(...)` but for studios — Jellyfin has no separate
    /// "Network" concept, a show's originating network and a movie's
    /// production studio are both stored as `Studios`, so the movie/show
    /// split for Home's "Movies from X"/"Shows from X" rails comes purely
    /// from `includeItemTypes` here, not a different endpoint.
    func studios(userID: String, includeItemTypes: [String]) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        return try await get("/Studios", query: query)
    }

    /// People credited with the given role(s) (`personTypes`, e.g.
    /// `["Actor"]`/`["Director"]`) anywhere in the user's library — unlike
    /// `genres(...)`/`studios(...)`, Jellyfin's `/Persons` has no
    /// `IncludeItemTypes` param, so this can't be (and isn't, by design —
    /// see `DynamicRailCandidate.actor`/`.director`) scoped to movies vs.
    /// shows separately the way genre/studio rails are.
    ///
    /// `limit`, unlike `genres(...)`/`studios(...)`, is worth actually
    /// passing here rather than always fetching everything — genre/studio
    /// counts are naturally small (a few dozen at most), but a library's
    /// full cast/crew corpus can run into the thousands of distinct
    /// people, each a full `BaseItemDto`, on every single Home load just to
    /// seed rail *candidates* (most of which won't even clear the
    /// minimum-item-count bar to become a rail — see
    /// `HomeViewModel.minimumDynamicRailItemCount`).
    func persons(userID: String, personTypes: [String], limit: Int? = nil) async throws -> BaseItemDtoQueryResult {
        var query = [URLQueryItem(name: "userId", value: userID)]
        if !personTypes.isEmpty {
            query.append(.init(name: "personTypes", value: personTypes.joined(separator: ",")))
        }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Persons", query: query)
    }

    /// `fields` overridable, same shape/reasoning as `items(...)`'s own
    /// `fields:` param — a caller that needs more than `detailFields`
    /// (e.g. `PlayerViewModel.start()`, which also wants `Trickplay`) can
    /// ask for it without widening the default every other caller of this
    /// method pays for too. `AssetDetailViewModel` alone calls this at
    /// several sites, some of them polling loops that fire repeatedly —
    /// none of them need trickplay data, so `detailFields` itself stays
    /// lean.
    func item(userID: String, itemID: String, fields: String = detailFields) async throws -> BaseItemDto {
        try await get("/Users/\(userID)/Items/\(itemID)", query: [.init(name: "Fields", value: fields)])
    }

    func resumeItems(userID: String, limit: Int = 12) async throws -> BaseItemDtoQueryResult {
        try await get("/Users/\(userID)/Items/Resume", query: [
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.defaultFields)
        ])
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

    func episodes(seriesID: String, seasonID: String, userID: String) async throws -> BaseItemDtoQueryResult {
        try await get("/Shows/\(seriesID)/Episodes", query: [
            .init(name: "seasonId", value: seasonID),
            .init(name: "userId", value: userID),
            .init(name: "Fields", value: Self.defaultFields)
        ])
    }

    /// With `seriesID` omitted, returns next-up episodes across every show
    /// the user's watching — Home's "Next Up" rail. With it set, narrows to
    /// just that series — `AssetDetailViewModel.resolveShowPlaybackEpisode`
    /// uses this to find a Series-direct page's Play/Resume target, and
    /// doesn't need `limit`/`Fields` (it only reads the first result), so
    /// both stay optional/omitted for that call site rather than forcing
    /// them on it.
    func nextUp(userID: String, seriesID: String? = nil, limit: Int? = nil) async throws -> BaseItemDtoQueryResult {
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Fields", value: Self.defaultFields)
        ]
        if let seriesID { query.append(.init(name: "SeriesId", value: seriesID)) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Shows/NextUp", query: query)
    }

    /// The episode immediately following `currentEpisodeID`, regardless of
    /// watched state — unlike `nextUp(userID:seriesID:)` above, which keeps
    /// returning the *current* episode until the server has confirmed it
    /// `played` (see `AssetDetailViewModel.advanceToNextEpisodeIfCompleted`'s
    /// own poll-and-wait dance for that, and `[[jellyfin-userdata-commit-
    /// latency]]`). `PlayerViewModel`'s in-player "Up Next" countdown needs
    /// the real next episode instantly, mid-playback, well before any of
    /// that can settle, so it uses this instead.
    ///
    /// Fetches the current season's episode list, sorts by `indexNumber`,
    /// and returns whatever follows `currentEpisodeID`. If that episode is
    /// last in its season (or, degenerately, not found in the list at all),
    /// falls through to the next *season*'s first episode instead of
    /// stopping at the season boundary. Returns `nil` when there's no next
    /// season or it's empty — the series has finished.
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

    /// "More Like This" for a detail page.
    func similarItems(itemID: String, userID: String, limit: Int = 12) async throws -> BaseItemDtoQueryResult {
        try await get("/Items/\(itemID)/Similar", query: [
            .init(name: "userId", value: userID),
            .init(name: "limit", value: String(limit)),
            .init(name: "Fields", value: Self.defaultFields)
        ])
    }

    /// The stock Jellyfin API has no direct "which collections contain this
    /// item" lookup, so this fetches every BoxSet, then checks each one's
    /// membership with its own request. Two things kept this from scaling
    /// past a personal server's modest collection count, found live once a
    /// server actually had a couple dozen: firing all `boxSets.count`
    /// membership checks at once could mean upwards of 100 concurrent
    /// requests for one detail page's "Included In" rail, and a single
    /// flaky one among them (`withThrowingTaskGroup`, `try await` inside
    /// each task) failed the *entire* call — which `load()` then let take
    /// down the whole page, not just this one rail. Fixed two ways: capped
    /// concurrency (`maxConcurrency` in-flight at once, not the whole list),
    /// and each membership check now fails soft (`try?` — a hiccup reads as
    /// "not a match," not a thrown error) via a plain `withTaskGroup`
    /// instead of the throwing variant. The one request this *can* still
    /// throw for is the initial BoxSets probe itself — `load()` treats this
    /// whole call as non-fatal regardless (see its own doc comment), so
    /// that's still safe to propagate rather than pretend to have an answer
    /// for.
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
                    // `fields: ""` — this only needs each child's `id` to
                    // check membership, none of `defaultFields`' heavier
                    // payload (Overview/Genres/Studios/...) that would
                    // otherwise be fetched and immediately discarded for
                    // every item in every collection.
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

    /// Skippable Intro/Outro/Recap/Preview/Commercial time ranges for an
    /// item — see `MediaSegmentType`'s doc comment for the server-version
    /// caveat. Unfiltered (includes `.unknown`-typed segments, if any); the
    /// caller (`PlaybackSegment.init?(dto:)`) drops those.
    func mediaSegments(itemID: String) async throws -> [MediaSegmentDto] {
        let result: MediaSegmentDtoQueryResult = try await get("/MediaSegments/\(itemID)")
        return result.items
    }

    // MARK: - Playback

    func playbackInfo(itemID: String, userID: String, mediaSourceID: String? = nil) async throws -> PlaybackInfoResponse {
        try await post("/Items/\(itemID)/PlaybackInfo", body: PlaybackInfoRequest(userId: userID, mediaSourceId: mediaSourceID))
    }

    /// Builds a direct-play stream URL. Sufficient for content the device
    /// can decode natively; real transcode negotiation via `PlaybackInfo`'s
    /// `DeviceProfile` is a follow-up.
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

    /// Builds a direct-fetch URL for an external subtitle stream (a
    /// `MediaStream` with `isExternal == true`). Deliberately does NOT read
    /// `MediaStream.deliveryUrl` — confirmed live against a real server that
    /// Jellyfin only populates that field when the `/PlaybackInfo` request
    /// carries a `DeviceProfile` negotiating subtitle delivery, which this
    /// app's direct-play-only `playbackInfo(itemID:userID:mediaSourceID:)`
    /// doesn't send, so the field comes back `nil` for every external
    /// stream in practice. Instead this builds Jellyfin's own well-known
    /// subtitle route directly (`/Videos/{itemId}/{mediaSourceId}/
    /// Subtitles/{streamIndex}/Stream.{format}`), same as `streamURL`
    /// builds the video route by hand. AetherEngine's side-demuxer fetches
    /// this directly over HTTP itself — outside this actor, with no
    /// `X-Emby-Authorization` header — so the token has to travel as the
    /// same `ApiKey` query item `streamURL` uses.
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

    /// Maps a `MediaStream.codec` to the file extension Jellyfin's subtitle
    /// route needs to serve the sidecar file byte-for-byte rather than
    /// running it through a server-side format conversion. Unknown/absent
    /// codecs fall back to "srt" — by far the most common external
    /// subtitle format, and Jellyfin serves *something* for it rather than
    /// a 404.
    private static func subtitleFileExtension(forCodec codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass": return "ass"
        case "ssa": return "ssa"
        case "webvtt", "vtt": return "vtt"
        default: return "srt"
        }
    }

    /// The live session Jellyfin's server is tracking for this device —
    /// diagnostics-only, for `PlaybackStatsOverlay`'s "Streaming" section
    /// (server-reported play method, and live transcode parameters when
    /// applicable). Filtered by `DeviceId`, which every request already
    /// identifies itself with via `X-Emby-Authorization` (see
    /// `JellyfinAuthorization`), so this is normally exactly one entry.
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

    func reportPlaybackStart(itemID: String, mediaSourceID: String? = nil) async throws {
        try await postNoContent(
            "/Sessions/Playing",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: 0, mediaSourceId: mediaSourceID)
        )
    }

    func reportPlaybackProgress(itemID: String, positionTicks: Int64, isPaused: Bool, mediaSourceID: String? = nil) async throws {
        try await postNoContent(
            "/Sessions/Playing/Progress",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: positionTicks, isPaused: isPaused, mediaSourceId: mediaSourceID)
        )
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64, mediaSourceID: String? = nil) async throws {
        try await postNoContent(
            "/Sessions/Playing/Stopped",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: positionTicks, mediaSourceId: mediaSourceID)
        )
    }

    // MARK: - Favorite / watched status

    /// `POST`s to favorite, `DELETE`s to unfavorite —
    /// `/Users/{userId}/FavoriteItems/{itemId}`, Jellyfin's standard toggle
    /// shape (no request body either way). Used by `PlayResumeButtonRow`'s
    /// favorite button — a plain toggle on a Movie/Episode-content page, or
    /// one of up to three independent targets (Show/Season/Episode) on a
    /// Show-content page's extended menu.
    func setFavorite(_ isFavorite: Bool, itemID: String, userID: String) async throws {
        try await sendNoContent(path: "/Users/\(userID)/FavoriteItems/\(itemID)", method: isFavorite ? "POST" : "DELETE")
    }

    /// Same `POST`-to-mark/`DELETE`-to-unmark shape as `setFavorite`, for
    /// `/Users/{userId}/PlayedItems/{itemId}` (Jellyfin's "watched" status).
    /// Marking a Series or Season played cascades server-side to every
    /// episode beneath it — this just issues the one request Jellyfin
    /// already expects for that; nothing client-side needs to fan it out.
    func setWatched(_ isWatched: Bool, itemID: String, userID: String) async throws {
        try await sendNoContent(path: "/Users/\(userID)/PlayedItems/\(itemID)", method: isWatched ? "POST" : "DELETE")
    }

    // MARK: - Search

    /// Jellyfin's dedicated `/Search/Hints` endpoint — SearchView's sole
    /// source of search results (a lighter-weight, purpose-built lookup,
    /// not the general-purpose `items(...)`/`/Items` used everywhere else).
    /// `includeItemTypes` is comma-delimited here, same as `items(...)`'s
    /// (confirmed against the real `SearchController.GetSearchHints`
    /// signature).
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

    /// Like `postNoContent`, but for an endpoint that also needs no request
    /// body at all (`setFavorite`/`setWatched`'s `POST`/`DELETE` toggle
    /// shape) — `method` rather than always `"POST"` is the only difference.
    private func sendNoContent(path: String, method: String) async throws {
        let request = try makeRequest(path: path, method: method)
        _ = try await sendRaw(request)
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
        // Never serve a cached response. Jellyfin's item endpoints reflect
        // fast-moving user state (resume position, played %, etc.) that has
        // to be fresh — the default `useProtocolCachePolicy` was letting the
        // detail-page refresh after playback show stale progress.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Per-request override of `.shared`'s default 60s
        // `timeoutIntervalForRequest` — see `requestTimeout`'s doc comment.
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            JellyfinAuthorization.headerValue(token: requiresAuth ? accessToken : nil),
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        if requiresAuth, let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        }

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

    /// `.shared`'s default `timeoutIntervalForRequest` is 60s — fine
    /// generally, but far too slow for offline detection: when *some*
    /// network path exists (cellular, a different Wi-Fi network, ...) but
    /// it can't actually route to a LAN-only server, the OS attempts a
    /// real connection and only gives up after the full timeout elapses,
    /// which read as an indefinite hang (the launch splash screen never
    /// resolving — confirmed live, 2026-08-18) rather than a prompt
    /// "you're offline". Enforced via `URLRequest.timeoutInterval`, set
    /// per-request in `makeRequest` — that's honored by `URLSession`
    /// regardless of which session dispatches the request, so this doesn't
    /// need a session with a shorter `timeoutIntervalForRequest`, which
    /// broke every test that builds its `JellyfinAPIClient` internally
    /// (`AppState`/`LoginViewModel`/`ServerSetupViewModel`) and relies on
    /// `URLProtocol.registerClass` hooking `.shared` specifically; a
    /// freshly constructed session doesn't pick up that registration. (An
    /// earlier version of this enforced the timeout via an explicit race
    /// against `Task.sleep` in a `withThrowingTaskGroup` instead, for the
    /// same reason — that worked too, but spun up an extra `Task` on every
    /// single request in the app just to get a timeout `URLRequest` already
    /// supports natively.) Matches `RemoteImageLoader`'s own 20s session
    /// timeout for consistency — short enough to fail fast, long enough not
    /// to misfire on a real but momentarily slow/loaded local server.
    private static let requestTimeout: TimeInterval = 20

    @discardableResult
    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.indicatesOffline {
            await ConnectivityMonitor.shared.reportFailure()
            throw urlError
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinAPIError.invalidResponse }
        // Reaching a real HTTP response — success or an error status — means
        // the server was reachable, so this is what clears offline state.
        await ConnectivityMonitor.shared.reportSuccess()
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinAPIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8))
        }
        return data
    }
}
