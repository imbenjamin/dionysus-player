#if DEBUG
import Foundation
import UIKit

/// Serves `UITestFixtureLibrary` in place of a real Jellyfin server.
///
/// Installed process-wide via `URLProtocol.registerClass`, which is enough to
/// cover `JellyfinAPIClient`: it is an `actor` whose only session seam is
/// `init(baseURL:accessToken:session: = .shared)`, and `AppState` never
/// passes a session, so every API call runs on `URLSession.shared`. The
/// sessions that *aren't* `.shared` — `RemoteImageLoader`'s and
/// `DownloadManager`'s — insert this class into their own
/// `configuration.protocolClasses` instead; see
/// `UITestHarness.decorate(_:)`.
///
/// Unlike the unit suite's `MockURLProtocol`, this router is declarative
/// rather than closure-driven. It has to be: XCUITest runs the assertions in
/// a separate process from the app, so there is no way to hand a
/// `requestHandler` closure across the boundary. Behaviour varies only by
/// the launch-time `UITestScenario`.
final class UITestStubURLProtocol: URLProtocol {
    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept everything while the harness is active. A UI test that
        // reaches the real network is a bug, not a fallback, so there is
        // deliberately no passthrough.
        UITestConfiguration.isActive
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            finish(.failure(URLError(.badURL)))
            return
        }

        let scenario = UITestConfiguration.scenario
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if scenario == .offline {
            finish(.failure(URLError(.notConnectedToInternet)))
            return
        }

        // Images resolve before any scenario gating: an error scenario is
        // about the *data* endpoints, and failing artwork too would just
        // park every assertion on a placeholder.
        if path.contains("/Images/") {
            finish(.success((200, Self.placeholderPNG, "image/png")))
            return
        }

        if let failure = Self.scenarioFailure(scenario: scenario, path: path) {
            finish(.success((failure, Data("{}".utf8), "application/json")))
            return
        }

        // Independent of scenario — a login journey testing a mistyped
        // password shouldn't need a whole error scenario switched on to get
        // there. Checked here rather than folded into `scenarioFailure`,
        // which gates *paths*, not *bodies*: this is the one request the
        // stub actually has to look inside to answer correctly.
        if path.hasSuffix("/Users/AuthenticateByName"), !Self.suppliesTheFixturePassword(request) {
            finish(.success((401, Data("{}".utf8), "application/json")))
            return
        }

        // Deletion is the one route that has to be matched on *method* as
        // well as path — `DELETE /Items/{id}` would otherwise fall through
        // to the `/Users/.../Items/{id}` item lookup below and answer a
        // deletion with a JSON item body.
        if request.httpMethod == "DELETE", let itemID = Self.deletedItemID(forPath: path) {
            // Mirrors the real server: refuse when this user has no delete
            // rights, with Jellyfin's own (surprising) 401 rather than a
            // 403 — see `JellyfinAPIClient.deleteItem`.
            guard scenario != .noDeletePermission else {
                finish(.success((401, Data("{}".utf8), "application/json")))
                return
            }
            Self.recordDeletion(of: itemID)
            finish(.success((204, Data(), "application/json")))
            return
        }

        do {
            let body = try Self.body(forPath: path, query: query, request: request)
            finish(.success((200, body, "application/json")))
        } catch {
            finish(.failure(error))
        }
    }

    override func stopLoading() {}

    // MARK: - Scenario gating

    /// Endpoints that must keep working in an error scenario, so a test
    /// still reaches a signed-in error state instead of being stranded on
    /// the login screen.
    private static func isInfrastructurePath(_ path: String) -> Bool {
        path.hasSuffix("/System/Info/Public")
            || path.hasSuffix("/health")
            || path.hasSuffix("/Users/AuthenticateByName")
    }

    /// Paths already served a 401 in this process, so `.unauthorized` fails
    /// each endpoint exactly once and then succeeds — which is what
    /// `JellyfinAPIClient.sendRaw`'s silent re-authentication is supposed to
    /// recover from. Failing forever would test a permanent outage instead.
    ///
    /// `nonisolated(unsafe)`: `URLProtocol` instances load on URLSession's
    /// own queues, so this is guarded by `lock` rather than by isolation.
    nonisolated(unsafe) private static var challengedPaths: Set<String> = []
    private static let lock = NSLock()

    /// Items deleted during this app session.
    ///
    /// The fixture library is otherwise immutable, which is fine for every
    /// read-only journey — but a deletion test's whole point is that the
    /// item is *gone* afterwards, so the stub has to carry that much state.
    /// Deliberately the minimum: a set of ids filtered out of every
    /// subsequent response (`scoped`), rather than a mutable copy of the
    /// catalogue. Process-lifetime, so each test's fresh app launch starts
    /// clean without needing an explicit reset.
    ///
    /// `nonisolated(unsafe)` + `lock` for the same reason as
    /// `challengedPaths` above.
    nonisolated(unsafe) private static var deletedItemIDs: Set<String> = []

    /// The item id in a `DELETE /Items/{id}`, or `nil` if this isn't that
    /// route. Matched precisely rather than with `contains("/Items/")` so a
    /// path like `/Users/{id}/Items/{id}` can't be mistaken for it.
    private static func deletedItemID(forPath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "Items" else { return nil }
        return String(components[1])
    }

    private static func recordDeletion(of itemID: String) {
        lock.lock()
        defer { lock.unlock() }
        deletedItemIDs.insert(itemID)
        // Deleting a season or show takes its episodes with it, exactly as
        // the real server does — otherwise a "the show is now empty" journey
        // would still see every episode.
        for episode in UITestFixtureLibrary.episodes
        where episode.seasonId == itemID || episode.seriesId == itemID {
            deletedItemIDs.insert(episode.id)
        }
        for season in UITestFixtureLibrary.seasons where season.seriesId == itemID {
            deletedItemIDs.insert(season.id)
        }
    }

    private static func isDeleted(_ itemID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deletedItemIDs.contains(itemID)
    }

    /// Episodes still present under a series — what the app's own
    /// "did that leave the show empty?" check reads back as
    /// `RecursiveItemCount`.
    private static func remainingEpisodeCount(seriesID: String) -> Int {
        UITestFixtureLibrary.episodes
            .filter { $0.seriesId == seriesID && !isDeleted($0.id) }
            .count
    }

    /// Whether the posted body's password matches the fixture credential —
    /// the whole check a "bad credentials" login journey needs. Any body
    /// this can't decode (a malformed request, or none at all) counts as
    /// not matching rather than crashing the stub.
    private static func suppliesTheFixturePassword(_ request: URLRequest) -> Bool {
        guard let body = requestBody(of: request),
              let decoded = try? JellyfinJSON.decoder.decode(AuthenticateByNameRequest.self, from: body) else {
            return false
        }
        return decoded.pw == UITestFixtureIdentity.password
    }

    /// `URLRequest.httpBody` is `nil` by the time a request reaches
    /// `URLProtocol` — measured live: `URLSession` converts even a small,
    /// directly-set body into `httpBodyStream` before handing the request to
    /// a registered protocol, for every request this app sends through
    /// `post(_:body:)`. This reads that stream instead, which is the only
    /// place the bytes still exist.
    private static func requestBody(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func scenarioFailure(scenario: UITestScenario, path: String) -> Int? {
        guard !isInfrastructurePath(path) else { return nil }
        switch scenario {
        // `.noDeletePermission` fails nothing wholesale — it's the standard
        // catalogue with `canDelete` cleared, and only `DELETE` itself
        // refused (handled in `startLoading`, which needs the method).
        case .standard, .emptyLibrary, .offline, .noDeletePermission:
            return nil
        case .serverError:
            return 500
        case .unauthorized:
            lock.lock()
            defer { lock.unlock() }
            guard !challengedPaths.contains(path) else { return nil }
            challengedPaths.insert(path)
            return 401
        }
    }

    // MARK: - Routing

    private struct UnroutedPath: Error { let path: String }

    private static func body(forPath path: String, query: [URLQueryItem], request: URLRequest) throws -> Data {
        let library = UITestFixtureLibrary.self

        switch true {
        case path.hasSuffix("/System/Info/Public"):
            return try encode(library.publicSystemInfo)

        case path.hasSuffix("/health"):
            return Data("Healthy".utf8)

        case path.hasSuffix("/Users/AuthenticateByName"):
            return try encode(library.authenticationResult)

        case path.hasSuffix("/Views"):
            return try encode(result(scoped(library.libraries)))

        case path.hasSuffix("/Items/Latest"):
            // The one endpoint that returns a bare array rather than a
            // `BaseItemDtoQueryResult`.
            return try encode(scoped(Array(library.movies.prefix(8))))

        case path.hasSuffix("/Items/Resume"):
            let resumable = library.movies.filter { ($0.userData?.playbackPositionTicks ?? 0) > 0 }
                + library.episodes.filter { ($0.userData?.playbackPositionTicks ?? 0) > 0 }
            return try encode(result(scoped(resumable)))

        case path.hasSuffix("/Shows/NextUp"):
            return try encode(result(scoped([library.episodes[1]])))

        case path.hasSuffix("/Seasons"):
            return try encode(result(scoped(library.seasons)))

        case path.hasSuffix("/Episodes"):
            let seasonID = query.first(where: { $0.name.caseInsensitiveCompare("SeasonId") == .orderedSame })?.value
            let episodes = seasonID.map { id in library.episodes.filter { $0.seasonId == id } } ?? library.episodes
            return try encode(result(scoped(episodes)))

        case path.hasSuffix("/Genres"):
            return try encode(result(scoped(named(Set(library.movies.compactMap { $0.genres?.first })))))

        case path.hasSuffix("/Studios"):
            return try encode(result(scoped(named(Set(library.movies.compactMap { $0.studios?.first?.name })))))

        case path.hasSuffix("/Persons"):
            let people = Set(library.movies.flatMap { $0.people ?? [] }.map(\.name))
            return try encode(result(scoped(named(people))))

        case path.hasSuffix("/Similar"):
            return try encode(result(scoped(Array(library.movies.dropFirst().prefix(6)))))

        case path.hasSuffix("/Search/Hints"):
            let term = query.first(where: { $0.name.caseInsensitiveCompare("SearchTerm") == .orderedSame })?.value ?? ""
            return try encode(searchHints(term: term))

        case path.contains("/Playlists/") && path.hasSuffix("/Items"):
            return try encode(result(scoped(library.playlistMembers)))

        case path.contains("/MediaSegments"):
            // Decoded as a query result, not a bare array — see
            // `JellyfinAPIClient.mediaSegments(itemID:)`.
            return try encode(MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0))

        case path.hasSuffix("/Sessions"):
            return try encode([SessionInfoDto]())

        // Media bytes: the stream a download pulls, and the subtitle files
        // the player side-loads. Playback itself never reaches here — the
        // fake engine is handed a URL it never opens — but `DownloadManager`
        // really does write these bytes to disk.
        //
        // Video specifically has to be a *parseable* MP4, not arbitrary
        // bytes: `DownloadManager.validationFailureReason` opens every
        // finished download with `AVURLAsset` and rejects it as unverifiable
        // if the duration won't load (see that method's doc comment — it
        // exists because a crashed transcode still closes as a clean HTTP
        // 200). Arbitrary bytes fail that check, and the download lands in
        // `.failed` — correct app behaviour, but it makes a completed
        // download untestable. See `syntheticMP4(durationSeconds:)`.
        case path.contains("/Videos/"):
            return syntheticMP4(durationSeconds: runtimeSeconds(forVideoPath: path))

        case path.contains("/Subtitles/"):
            return Data(repeating: 0, count: 4096)

        case path.hasSuffix("/PlaybackInfo"):
            return try encode(playbackInfo(forPath: path))

        // `/Users/{userID}/Items/{itemID}` — a single item. Checked before
        // the collection route below, which shares its prefix.
        case path.contains("/Users/") && path.contains("/Items/") && !path.hasSuffix("/Items"):
            let itemID = path.components(separatedBy: "/Items/").last?
                .components(separatedBy: "/").first ?? ""
            guard let item = library.allItems[itemID], !isDeleted(itemID) else {
                throw UnroutedPath(path: path)
            }
            var resolved = applyDeletePermission(item)
            // The count the app re-reads after a deletion to decide whether
            // the show still has anything in it — see
            // `AssetDetailViewModel.resolveDeletionOutcome(for:)`. Computed
            // live rather than baked into the fixture, so it actually falls
            // as episodes are deleted.
            if resolved.type == .series {
                resolved.recursiveItemCount = remainingEpisodeCount(seriesID: itemID)
            }
            return try encode(resolved)

        case path.hasSuffix("/Items"):
            return try encode(result(items(matching: query)))

        default:
            // Writes: favourite, watched, progress reporting, playback
            // session lifecycle. The app sends these and never decodes a
            // body back, so an empty 200 is the whole contract.
            //
            // Deliberately *after* the routing above, not before it. An
            // earlier version short-circuited every POST here, which
            // silently swallowed `/Users/AuthenticateByName` — a POST whose
            // response the app very much does decode — and every test failed
            // far downstream, at "Home has no content", with sign-in
            // appearing to have worked.
            if request.httpMethod == "POST" || request.httpMethod == "DELETE" {
                return Data()
            }
            throw UnroutedPath(path: path)
        }
    }

    // MARK: - `/Users/{id}/Items` query engine

    /// Applies the subset of Jellyfin's `/Items` query the app actually
    /// sends. Filtering here rather than always returning the full catalogue
    /// is what makes `CollectionGridView`'s server-side sort and its
    /// library-scoped grids assert anything real.
    private static func items(matching query: [URLQueryItem]) -> [BaseItemDto] {
        func value(_ name: String) -> String? {
            query.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func list(_ name: String, separator: Character) -> [String] {
            value(name)?.split(separator: separator).map(String.init) ?? []
        }

        var items = UITestFixtureLibrary.browsableItems

        if let parentID = value("ParentId") {
            items = items.filter { belongs($0, toLibrary: parentID) }
        }

        let includeTypes = Set(list("IncludeItemTypes", separator: ","))
        if !includeTypes.isEmpty {
            items = items.filter { includeTypes.contains($0.type.rawValue) }
        }

        let excludeTypes = Set(list("ExcludeItemTypes", separator: ","))
        if !excludeTypes.isEmpty {
            items = items.filter { !excludeTypes.contains($0.type.rawValue) }
        }

        let genres = Set(list("Genres", separator: "|"))
        if !genres.isEmpty {
            items = items.filter { !genres.isDisjoint(with: Set($0.genres ?? [])) }
        }

        let studios = Set(list("Studios", separator: "|"))
        if !studios.isEmpty {
            items = items.filter { !studios.isDisjoint(with: Set(($0.studios ?? []).map(\.name))) }
        }

        for filter in list("Filters", separator: ",") {
            switch filter {
            case "IsPlayed":     items = items.filter { $0.userData?.played == true }
            case "IsUnplayed":   items = items.filter { $0.userData?.played != true }
            case "IsFavorite":   items = items.filter { $0.userData?.isFavorite == true }
            default:             break
            }
        }

        if let person = value("Person") {
            items = items.filter { ($0.people ?? []).contains { $0.name == person } }
        }

        if let term = value("SearchTerm"), !term.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(term) }
        }

        items = sorted(items, by: value("SortBy") ?? "SortName", ascending: value("SortOrder") != "Descending")

        if let limit = value("Limit").flatMap(Int.init) {
            items = Array(items.prefix(limit))
        }

        return scoped(items)
    }

    private static func belongs(_ item: BaseItemDto, toLibrary parentID: String) -> Bool {
        switch parentID {
        case UITestFixtureLibrary.moviesLibraryID:
            return item.type == .movie
        case UITestFixtureLibrary.showsLibraryID:
            return item.type == .series || item.type == .season || item.type == .episode
        case UITestFixtureLibrary.boxSetsLibraryID:
            return item.type == .boxSet
        case UITestFixtureLibrary.playlistsLibraryID:
            return item.type == .playlist
        case UITestFixtureLibrary.boxSetID:
            return UITestFixtureLibrary.boxSetMembers.contains { $0.id == item.id }
        case UITestFixtureLibrary.seriesID:
            return item.seriesId == UITestFixtureLibrary.seriesID
        default:
            // An unrecognised parent is a season, a playlist, or something
            // the app invented — match on parentage rather than dropping
            // everything, which would read as an empty library.
            return item.seasonId == parentID
        }
    }

    private static func sorted(_ items: [BaseItemDto], by field: String, ascending: Bool) -> [BaseItemDto] {
        let ordered: [BaseItemDto]
        switch field {
        case "Random":
            // Seeded, not random: a UI test asserting on "a random item"
            // needs the same item every run, and the *routing* is what the
            // dice button's test is checking, not the entropy.
            ordered = items.sorted { $0.id > $1.id }
        case "ProductionYear", "PremiereDate":
            ordered = items.sorted { ($0.productionYear ?? 0, $0.name) < ($1.productionYear ?? 0, $1.name) }
        case "CommunityRating":
            ordered = items.sorted { ($0.communityRating ?? 0, $0.name) < ($1.communityRating ?? 0, $1.name) }
        case "Runtime":
            ordered = items.sorted { ($0.runTimeTicks ?? 0, $0.name) < ($1.runTimeTicks ?? 0, $1.name) }
        case "DateCreated", "DatePlayed":
            ordered = items.sorted { $0.id < $1.id }
        default:
            ordered = items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        return ascending ? ordered : ordered.reversed()
    }

    // MARK: - Response shaping

    /// `.emptyLibrary` empties every collection at the last possible moment,
    /// so each route keeps its real shape and only the contents change.
    ///
    /// Anything deleted this session drops out here too, for the same
    /// reason — one choke point every list route already passes through, so
    /// a deleted item can't reappear in a rail, grid, season list or search
    /// result. `.noDeletePermission` additionally clears `canDelete`, which
    /// is what makes the affordance vanish app-wide for that scenario.
    private static func scoped(_ items: [BaseItemDto]) -> [BaseItemDto] {
        guard UITestConfiguration.scenario != .emptyLibrary else { return [] }
        return items
            .filter { !isDeleted($0.id) }
            .map(applyDeletePermission)
    }

    /// The fixtures are built deletable (see `UITestFixtureLibrary.base`);
    /// this is what takes that away for the no-permission scenario, so both
    /// halves of the gate are exercised from one catalogue rather than two.
    private static func applyDeletePermission(_ item: BaseItemDto) -> BaseItemDto {
        guard UITestConfiguration.scenario == .noDeletePermission else { return item }
        var copy = item
        copy.canDelete = false
        return copy
    }

    private static func result(_ items: [BaseItemDto]) -> BaseItemDtoQueryResult {
        BaseItemDtoQueryResult(items: items, totalRecordCount: items.count)
    }

    /// Jellyfin returns `/Genres`, `/Studios` and `/Persons` as `BaseItemDto`
    /// values whose only meaningful field is the name.
    private static func named(_ names: Set<String>) -> [BaseItemDto] {
        names.sorted().map { name in
            BaseItemDto(id: "name-" + name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, type: .unknown)
        }
    }

    private static func searchHints(term: String) -> SearchHintResult {
        let matches = UITestConfiguration.scenario == .emptyLibrary
            ? []
            : UITestFixtureLibrary.browsableItems.filter { $0.name.localizedCaseInsensitiveContains(term) }
        let hints = matches.map { item in
            SearchHint(
                id: item.id,
                name: item.name,
                type: item.type,
                productionYear: item.productionYear,
                series: item.seriesName,
                indexNumber: item.indexNumber,
                parentIndexNumber: item.parentIndexNumber
            )
        }
        return SearchHintResult(searchHints: hints, totalRecordCount: hints.count)
    }

    private static func playbackInfo(forPath path: String) -> PlaybackInfoResponse {
        let itemID = path.components(separatedBy: "/Items/").last?
            .components(separatedBy: "/").first ?? ""
        let source = UITestFixtureLibrary.allItems[itemID]?.mediaSources?.first
        return PlaybackInfoResponse(
            mediaSources: source.map { [$0] } ?? [],
            playSessionId: "uitest-play-session",
            errorCode: nil
        )
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        try JellyfinJSON.encoder.encode(value)
    }

    // MARK: - Synthetic video

    /// The runtime `syntheticMP4(durationSeconds:)` should claim for the
    /// item a `/Videos/{itemID}/stream.mp4` request names, so the file
    /// `DownloadManager` validates matches the runtime it recorded at
    /// enqueue time. Falls back to an hour for anything unrecognised —
    /// long enough that no fixture's own runtime check could fail against
    /// it by accident.
    private static func runtimeSeconds(forVideoPath path: String) -> Double {
        let itemID = path.components(separatedBy: "/Videos/").last?
            .components(separatedBy: "/").first ?? ""
        guard let ticks = UITestFixtureLibrary.allItems[itemID]?.runTimeTicks else { return 3600 }
        return Double(ticks) / 10_000_000
    }

    /// A structurally valid, ~600-byte MP4 that declares `durationSeconds`
    /// of video and contains one byte of media data.
    ///
    /// Hand-assembled rather than produced by `AVAssetWriter`: the point is
    /// a file whose *declared* duration is a feature-length runtime while
    /// its actual size stays negligible, and a writer would have to encode
    /// the real thing to claim it.
    ///
    /// The duration has to come from the sample table, not from `mvhd`.
    /// Measured live: an otherwise-identical file with the runtime only in
    /// `mvhd`/`tkhd`/`mdhd` and empty `stts`/`stsz`/`stco` boxes loads
    /// fine but reports `duration == 0`, because `AVAsset` derives its
    /// duration from the longest *track*, and a track with no samples is
    /// zero-length however long its header claims to be. So the single
    /// sample below is given a `stts` delta spanning the whole runtime.
    private static func syntheticMP4(durationSeconds: Double) -> Data {
        let timescale: UInt32 = 600
        let duration = UInt32(durationSeconds * Double(timescale))

        func box(_ type: String, _ payload: Data) -> Data {
            u32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
        }

        let ftyp = box("ftyp", Data("isom".utf8) + u32(512) + Data("isomiso2avc1mp41".utf8))

        var mvhd = Data()
        mvhd += u32(0)                                  // version + flags
        mvhd += u32(0) + u32(0)                         // created, modified
        mvhd += u32(timescale) + u32(duration)
        mvhd += u32(0x0001_0000)                        // rate 1.0
        mvhd += u16(0x0100) + u16(0)                    // volume, reserved
        mvhd += u32(0) + u32(0)                         // reserved
        mvhd += unityMatrix
        mvhd += Data(repeating: 0, count: 24)           // predefined
        mvhd += u32(2)                                  // next track id

        var tkhd = Data()
        tkhd += u32(0x0000_0007)                        // v0, enabled|inMovie|inPreview
        tkhd += u32(0) + u32(0)
        tkhd += u32(1)                                  // track id
        tkhd += u32(0)                                  // reserved
        tkhd += u32(duration)
        tkhd += u32(0) + u32(0)                         // reserved
        tkhd += u16(0) + u16(0)                         // layer, alternate group
        tkhd += u16(0) + u16(0)                         // volume, reserved
        tkhd += unityMatrix
        tkhd += u32(64 << 16) + u32(64 << 16)           // width, height (16.16)

        var mdhd = Data()
        mdhd += u32(0)
        mdhd += u32(0) + u32(0)
        mdhd += u32(timescale) + u32(duration)
        mdhd += u16(0x55C4) + u16(0)                    // language 'und', predefined

        let hdlr = box("hdlr", u32(0) + u32(0) + Data("vide".utf8) + u32(0) + u32(0) + u32(0) + Data([0]))
        let vmhd = box("vmhd", u32(1) + u16(0) + u16(0) + u16(0) + u16(0))
        let dinf = box("dinf", box("dref", u32(0) + u32(1) + box("url ", u32(1))))

        var avc1 = Data()
        avc1 += Data(repeating: 0, count: 6)            // reserved
        avc1 += u16(1)                                  // data reference index
        avc1 += u16(0) + u16(0)                         // predefined, reserved
        avc1 += u32(0) + u32(0) + u32(0)                // predefined
        avc1 += u16(64) + u16(64)                       // width, height
        avc1 += u32(0x0048_0000) + u32(0x0048_0000)     // 72dpi horiz/vert resolution
        avc1 += u32(0)                                  // reserved
        avc1 += u16(1)                                  // frame count
        avc1 += Data(repeating: 0, count: 32)           // compressor name
        avc1 += u16(0x0018) + u16(0xFFFF)               // depth, predefined

        /// The chunk offset in `stco` is an *absolute file* offset, so it
        /// can't be known until `moov`'s own size is. Built twice: the
        /// offset is a fixed-width `UInt32` either way, so the second pass
        /// is byte-identical in size to the first and no third is needed.
        func moov(sampleOffset: UInt32) -> Data {
            let stbl = box("stbl",
                box("stsd", u32(0) + u32(1) + box("avc1", avc1))
                    // One sample, spanning the entire runtime.
                    + box("stts", u32(0) + u32(1) + u32(1) + u32(duration))
                    + box("stsc", u32(0) + u32(1) + u32(1) + u32(1) + u32(1))
                    + box("stsz", u32(0) + u32(0) + u32(1) + u32(1))
                    + box("stco", u32(0) + u32(1) + u32(sampleOffset))
            )
            let mdia = box("mdia", box("mdhd", mdhd) + hdlr + box("minf", vmhd + dinf + stbl))
            let trak = box("trak", box("tkhd", tkhd) + mdia)
            return box("moov", box("mvhd", mvhd) + trak)
        }

        let sampleOffset = UInt32(ftyp.count + moov(sampleOffset: 0).count + 8)
        return ftyp + moov(sampleOffset: sampleOffset) + box("mdat", Data([0]))
    }

    /// The identity transform every MP4 header carries, as 3x3 fixed-point.
    private static let unityMatrix: Data = {
        [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
            .map(u32)
            .reduce(into: Data()) { $0 += $1 }
    }()

    private static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    // MARK: - Artwork

    /// A single flat-colour PNG standing in for every poster, backdrop, logo
    /// and cast photo. Generated once rather than bundled, so nothing about
    /// the harness ships as a Release resource.
    private static let placeholderPNG: Data = {
        let size = CGSize(width: 8, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.16, green: 0.14, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }()

    // MARK: - Completion

    /// `(status, body, contentType)` on success.
    private typealias Response = (status: Int, body: Data, contentType: String)

    private func finish(_ outcome: Result<Response, Error>) {
        switch outcome {
        case let .success((status, data, contentType)):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    // `ServerSetupViewModel.testConnection()` rewrites the
                    // persisted scheme from `client.lastResponseURL`, so the
                    // response URL has to be the request URL exactly —
                    // anything else silently changes the server config the
                    // test just entered.
                    headerFields: ["Content-Type": contentType]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
#endif
