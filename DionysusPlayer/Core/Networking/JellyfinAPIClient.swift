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

    /// Whatever credentials most recently succeeded via `authenticate(...)`
    /// — kept only so a request that comes back 401 mid-session (confirmed
    /// live against a heavily-shared public demo server: the session token
    /// this client was issued got invalidated server-side with no action
    /// by this app at all) can silently re-authenticate and retry, rather
    /// than surfacing a raw HTTP error for something the app can just
    /// recover from. `nil` before any successful sign-in, and explicitly
    /// cleared by `forgetReauthCredentials()` on sign-out — see `sendRaw`'s
    /// 401 handling for where this is actually used.
    private var reauthCredentials: (username: String, password: String)?
    /// Coalesces concurrent re-authentication attempts into one in-flight
    /// `Task` — several requests can 401 around the same moment (e.g.
    /// `HomeViewModel.load()`'s multi-endpoint fan-out), and each
    /// independently racing to re-authenticate would spam
    /// `/Users/AuthenticateByName` for no benefit. Safe to check-then-set
    /// without an explicit lock: this is actor-isolated state and neither
    /// line suspends, so nothing else can interleave between them.
    private var inFlightReauth: Task<Void, Error>?
    /// Delays before each re-authentication attempt after a 401 (the first
    /// attempt is immediate — index 0 is the delay *before the second*
    /// attempt) — same array-of-delays convention as `AssetDetailViewModel
    /// .userDataCommitPollSchedule`. Bounded rather than infinite: a
    /// genuinely revoked/stale credential must still surface
    /// `.notAuthenticated` and send the user back to the login screen
    /// instead of retrying forever.
    private static let reauthBackoffSchedule: [Double] = [0.5, 1.0, 2.0, 4.0]

    init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    /// Called on sign-out so this client (which `AppState` reuses across a
    /// sign-out/sign-back-in on the same server rather than reconstructing)
    /// doesn't keep the previous user's credentials around to silently
    /// re-authenticate with if something still 401s in flight.
    func forgetReauthCredentials() {
        reauthCredentials = nil
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
        // Remember these for `sendRaw`'s 401 auto-retry — see
        // `reauthCredentials`'s doc comment. Only updated on success, so a
        // failed sign-in (or a failed reauth attempt — see `reauthenticate
        // (attempt:)`) never overwrites a still-good previous credential
        // with a broken one.
        reauthCredentials = (username, password)
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
    /// a 404. Not `private` — `DownloadManager` also needs this to name a
    /// downloaded subtitle sidecar file correctly.
    static func subtitleFileExtension(forCodec codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass": return "ass"
        case "ssa": return "ssa"
        case "webvtt", "vtt": return "vtt"
        default: return "srt"
        }
    }

    /// True for bitmap/image-based subtitle formats (PGS, VobSub, DVB) —
    /// AetherEngine can render these live during normal playback just fine,
    /// but they genuinely can't be brought into an offline download:
    /// Jellyfin's subtitle-extraction endpoint (`subtitleURL`) has no
    /// server-side OCR to convert them to text, and MP4 has no way to embed
    /// a bitmap subtitle track either. Download-building callers must skip
    /// these rather than falling through `subtitleFileExtension(forCodec:)`'s
    /// `default: "srt"` case, which would otherwise silently mis-request a
    /// bitmap stream as a (garbage) `.srt` file.
    static func isImageBasedSubtitleCodec(_ codec: String?) -> Bool {
        switch codec?.lowercased() {
        case "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub":
            return true
        default:
            return false
        }
    }

    /// Builds a device-transcoded download URL for offline storage —
    /// H.265/HEVC MP4, resolution/bitrate capped to `resolution`/`preset`
    /// and never exceeding the source's own values (see
    /// `DownloadTranscodeCalculator.target`, which computes the actual
    /// `MaxWidth`/`MaxHeight`/`VideoBitrate`/`VideoProfile`/`MaxFramerate`
    /// sent below). Unlike `streamURL` (`Static=true`, direct play), this is
    /// never a plain file copy (`Static=false`): the whole point of a
    /// download is a device-friendly capped copy, so even a source already
    /// within the tier's bounds still gets re-muxed to MP4/AAC, which
    /// `Static=true` wouldn't do. Audio is always transcoded to AAC-LC
    /// stereo (`MaxAudioChannels=2`) regardless of the source's channel
    /// layout — a deliberate v1 simplification (see the offline-downloads
    /// plan).
    ///
    /// The *video* track, though, is only re-encoded when it actually needs
    /// to be. When the source already satisfies the requested tier
    /// (`DownloadTranscodeTarget.videoStreamCopyEligible` — see its
    /// conditions), this asks Jellyfin to copy the video stream into the
    /// output MP4 untouched via `AllowVideoStreamCopy`, rather than paying
    /// for a pointless second generation of lossy encoding. Audio is still
    /// transcoded either way, so the output shape is unchanged.
    ///
    /// Two non-obvious details, both established by testing against a real
    /// server rather than from the API docs:
    ///
    /// 1. **`VideoCodec` must list the source's own codec**, which is why
    ///    `requestedVideoCodecs` can be `"hevc,h264"`. Jellyfin only copies
    ///    a stream whose codec is among those the client said it wants; ask
    ///    for `hevc` alone against an H.264 source and the copy is silently
    ///    declined.
    /// 2. **The resolution/bitrate caps are still sent** on the copy path.
    ///    Jellyfin ignores them when it does copy, and they are the only
    ///    thing standing between a declined copy and a completely
    ///    unconstrained transcode. Omitting them (the first version of this)
    ///    turned a 1280×720 source into a **416×234, 343 Kbps** file, because
    ///    the copy was refused and nothing was left to bound the fallback.
    ///
    /// `ApiKey` travels as a query param, not a header, for the same reason
    /// `streamURL`/`subtitleURL` do: this URL is handed to a plain
    /// `URLSessionDownloadTask` outside this actor's own request pipeline.
    ///
    /// See `DOWNLOADS.md` for how the tiers and bitrates were chosen.
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
        sourceVideoCodec: String? = nil
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
            sourceVideoCodec: sourceVideoCodec
        )

        var query: [URLQueryItem] = [
            .init(name: "Static", value: "false"),
            .init(name: "Container", value: "mp4"),
            .init(name: "VideoCodec", value: target.requestedVideoCodecs.joined(separator: ",")),
            .init(name: "AudioCodec", value: "aac"),
            .init(name: "AudioBitrate", value: String(preset.audioBitrate)),
            .init(name: "MaxAudioChannels", value: "2"),
            // Sent even when a stream copy is expected. Jellyfin ignores
            // these on the copy path, and if it decides to transcode after
            // all they're the difference between a correctly-capped file and
            // an unconstrained one — see the doc comment above.
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
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        query.append(.init(name: "DeviceId", value: DeviceIdentity.deviceID))
        components.queryItems = query
        return components.url
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

    /// Directly sets a user's watched/resume state for an item — `POST
    /// /Users/{userId}/Items/{itemId}/UserData`. Used by the offline
    /// `DownloadSyncManager` instead of `reportPlaybackProgress`/
    /// `reportPlaybackStopped` above, both of which assume a live
    /// `PlaySessionId` an offline-recorded position won't have. This
    /// endpoint has no active-session requirement, which is exactly what
    /// "post an update hours or days later, once reconnected" needs.
    /// `lastPlayedDate` should be the real, on-device moment this actually
    /// happened (`DownloadedItem.lastPlayedAt`) — see
    /// `UpdateUserDataRequest.lastPlayedDate`'s doc comment for why this
    /// can't just be left for the server to infer.
    func updateUserData(itemID: String, userID: String, positionTicks: Int64, isPlayed: Bool, playedPercentage: Double, lastPlayedDate: Date? = nil) async throws {
        try await postNoContent(
            "/Users/\(userID)/Items/\(itemID)/UserData",
            body: UpdateUserDataRequest(
                playbackPositionTicks: positionTicks, played: isPlayed, playedPercentage: playedPercentage, lastPlayedDate: lastPlayedDate
            )
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
        try await sendRaw(request, reauthAttempt: 0)
    }

    /// `reauthAttempt` counts how many re-authentication attempts this
    /// specific logical request has already gone through (0 the first
    /// time) — bounds the recursion against `reauthBackoffSchedule` rather
    /// than retrying forever, and picks that attempt's backoff delay.
    private func sendRaw(_ request: URLRequest, reauthAttempt: Int) async throws -> Data {
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
            // Only a request built with `requiresAuth: true` carries this
            // header (see `makeRequest`) — `authenticate(...)`'s own 401
            // (a genuinely wrong password, at first sign-in) is sent with
            // `requiresAuth: false`, so it never reaches either branch
            // below and keeps throwing the raw `.http(401, ...)` as before.
            let isTokenBearing401 = http.statusCode == 401 && request.value(forHTTPHeaderField: "X-Emby-Token") != nil
            guard isTokenBearing401 else {
                throw JellyfinAPIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8))
            }

            // A token-bearing 401 doesn't necessarily mean these
            // credentials are actually bad: confirmed live against a
            // heavily-shared public demo server that a session token can
            // be invalidated server-side for reasons entirely outside this
            // app's control. Try to recover transparently — re-authenticate
            // with whatever credentials last succeeded and retry this same
            // request — before giving up.
            if let reauthCredentials, reauthAttempt < Self.reauthBackoffSchedule.count {
                do {
                    try await reauthenticate(using: reauthCredentials, attempt: reauthAttempt)
                } catch {
                    // Re-authentication itself failed (offline, or the
                    // credentials genuinely no longer work) — fall through
                    // to .notAuthenticated below rather than surfacing this
                    // secondary failure, which would just be confusing
                    // ("couldn't reach the server" for what the user
                    // experiences as "got logged out").
                    throw JellyfinAPIError.notAuthenticated
                }
                var retried = request
                retried.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
                retried.setValue(JellyfinAuthorization.headerValue(token: accessToken), forHTTPHeaderField: "X-Emby-Authorization")
                return try await sendRaw(retried, reauthAttempt: reauthAttempt + 1)
            }

            // Nothing left to retry with (no remembered credentials, or the
            // backoff schedule is exhausted). A raw `.http(401, ...)` here
            // used to surface the server's own HTML error page verbatim
            // (Jellyfin's default 401 response is a full branded HTML
            // document, not JSON); `.notAuthenticated` gives a clean,
            // actionable message instead.
            throw JellyfinAPIError.notAuthenticated
        }
        return data
    }

    /// Coalesces concurrent re-authentication attempts into one in-flight
    /// `Task` — see `inFlightReauth`'s doc comment for why. `attempt`
    /// selects this call's backoff delay from `reauthBackoffSchedule`
    /// (skipped on the very first retry, `attempt == 0`, so a one-off
    /// transient 401 recovers immediately rather than waiting).
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
