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

    private static func scenarioFailure(scenario: UITestScenario, path: String) -> Int? {
        guard !isInfrastructurePath(path) else { return nil }
        switch scenario {
        case .standard, .emptyLibrary, .offline:
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
        case path.contains("/Videos/") || path.contains("/Subtitles/"):
            return Data(repeating: 0, count: 4096)

        case path.hasSuffix("/PlaybackInfo"):
            return try encode(playbackInfo(forPath: path))

        // `/Users/{userID}/Items/{itemID}` — a single item. Checked before
        // the collection route below, which shares its prefix.
        case path.contains("/Users/") && path.contains("/Items/") && !path.hasSuffix("/Items"):
            let itemID = path.components(separatedBy: "/Items/").last?
                .components(separatedBy: "/").first ?? ""
            guard let item = library.allItems[itemID] else { throw UnroutedPath(path: path) }
            return try encode(item)

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
    private static func scoped(_ items: [BaseItemDto]) -> [BaseItemDto] {
        UITestConfiguration.scenario == .emptyLibrary ? [] : items
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
