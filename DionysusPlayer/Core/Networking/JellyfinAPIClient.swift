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
    private static let detailFields = "Overview,Genres,Studios,PrimaryImageAspectRatio,MediaSources,People,BasicSyncInfo"

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
        limit: Int? = nil
    ) async throws -> BaseItemDtoQueryResult {
        var query: [URLQueryItem] = [
            .init(name: "Recursive", value: String(recursive)),
            .init(name: "SortBy", value: sortBy),
            .init(name: "SortOrder", value: sortOrder),
            .init(name: "Fields", value: Self.defaultFields)
        ]
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

    func item(userID: String, itemID: String) async throws -> BaseItemDto {
        try await get("/Users/\(userID)/Items/\(itemID)", query: [.init(name: "Fields", value: Self.detailFields)])
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
    /// just that series — `AssetDetailViewModel.resolveSeriesPlaybackItemID`
    /// uses this to find where to resume a specific show, and doesn't need
    /// `limit`/`Fields` (it only reads the first result's ID), so both stay
    /// optional/omitted for that call site rather than forcing them on it.
    func nextUp(userID: String, seriesID: String? = nil, limit: Int? = nil) async throws -> BaseItemDtoQueryResult {
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Fields", value: Self.defaultFields)
        ]
        if let seriesID { query.append(.init(name: "SeriesId", value: seriesID)) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await get("/Shows/NextUp", query: query)
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
    /// item" lookup, so this fetches every BoxSet and checks membership.
    /// Fine for a personal server's collection count; worth revisiting if
    /// that stops being true.
    func collectionsContaining(itemID: String, userID: String) async throws -> [BaseItemDto] {
        let boxSets = try await items(userID: userID, includeItemTypes: ["BoxSet"], limit: 100).items
        guard !boxSets.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: BaseItemDto?.self) { group in
            for boxSet in boxSets {
                group.addTask {
                    let children = try await self.items(userID: userID, parentID: boxSet.id, recursive: false)
                    return children.items.contains(where: { $0.id == itemID }) ? boxSet : nil
                }
            }
            var matches: [BaseItemDto] = []
            for try await match in group {
                if let match { matches.append(match) }
            }
            return matches
        }
    }

    // MARK: - Playback

    func playbackInfo(itemID: String, userID: String) async throws -> PlaybackInfoResponse {
        try await post("/Items/\(itemID)/PlaybackInfo", body: PlaybackInfoRequest(userId: userID))
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

    /// Snapshot of the current base URL/token for building image URLs
    /// synchronously outside the actor — see `ImageURLBuilder`.
    func makeImageURLBuilder() -> ImageURLBuilder {
        ImageURLBuilder(baseURL: baseURL, accessToken: accessToken)
    }

    // MARK: - Playback progress reporting

    func reportPlaybackStart(itemID: String) async throws {
        try await postNoContent("/Sessions/Playing", body: PlaybackProgressRequest(itemId: itemID, positionTicks: 0))
    }

    func reportPlaybackProgress(itemID: String, positionTicks: Int64, isPaused: Bool) async throws {
        try await postNoContent(
            "/Sessions/Playing/Progress",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: positionTicks, isPaused: isPaused)
        )
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64) async throws {
        try await postNoContent(
            "/Sessions/Playing/Stopped",
            body: PlaybackProgressRequest(itemId: itemID, positionTicks: positionTicks)
        )
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

    @discardableResult
    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinAPIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8))
        }
        return data
    }
}
