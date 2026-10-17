import XCTest
@testable import Dionysus

/// The extension's fetch (M6): nothing without the mirrored session or a
/// server answering; never a password sign-in (Review Focus 1).
final class TopShelfLoaderTests: XCTestCase {
    private let session = TopShelfSession(
        serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
        accessToken: "tok", deviceID: "dev", deviceName: "Bedroom"
    )

    override func tearDown() {
        MockURLProtocol.reset()
        DeviceIdentity.adopt(deviceID: nil, deviceName: nil)
        super.tearDown()
    }

    func test_noSession_loadsNothing_andAsksNothing() async {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let entries = await TopShelfLoader.load(session: nil, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func test_401_loadsNothing_withoutSigningIn() async {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/AuthenticateByName") }, "The extension never signs in")
    }

    func test_success_buildsEntries_presentingTheAppsDeviceID() async {
        var headers: [String] = []
        MockURLProtocol.requestHandler = { request in
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Items/Latest") { return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]()) }
            var movie = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
            movie.backdropImageTags = ["t"]
            let items = path.hasSuffix("/Items/Resume") ? [movie] : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(entries.map(\.id), ["m1"])
        XCTAssertTrue(headers.allSatisfy { $0.contains("DeviceId=\"dev\"") }, "Every request carries the app's device id")
    }

    /// One source failing leaves the others on the shelf.
    func test_aFailingSource_leavesTheOthers() async {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            guard path.hasSuffix("/Items/Resume") else { return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }
            var movie = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
            movie.backdropImageTags = ["t"]
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [movie], totalRecordCount: 1))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(entries.map(\.id), ["m1"])
    }

    /// Home's libraries: the first Movies and the first TV Shows library.
    /// Music, books and a second library of either kind are never asked, and
    /// nothing asks `/Items/Latest` unscoped.
    func test_recentlyAdded_asksOnlyTheFirstMoviesAndShowsLibrary() async {
        let libraries = [
            Self.library("music", collectionType: JellyfinCollectionType.music),
            Self.library("shows", collectionType: JellyfinCollectionType.tvShows),
            Self.library("movies", collectionType: JellyfinCollectionType.movies),
            Self.library("books", collectionType: "books"),
            Self.library("movies2", collectionType: JellyfinCollectionType.movies)
        ]
        let latestByLibrary = [
            "music": [Self.backdropped("album", .movie)],
            "shows": [Self.backdropped("s1", .series), Self.backdropped("s2", .series)],
            "movies": [Self.backdropped("m1", .movie)],
            "books": [Self.backdropped("book", .movie)],
            "movies2": [Self.backdropped("m2", .movie)]
        ]
        var latestParents: [String?] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path.hasSuffix("/Items/Latest") {
                let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "ParentId" }?.value
                latestParents.append(parent)
                return try MockURLProtocol.encodedJSONResponse(for: request, value: parent.flatMap { latestByLibrary[$0] } ?? [])
            }
            let items = url.path.hasSuffix("/Views") ? libraries : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(Set(entries.map(\.id)), ["m1", "s1", "s2"])
        XCTAssertEqual(Set(latestParents.compactMap { $0 }), ["movies", "shows"])
        XCTAssertFalse(latestParents.contains(nil), "Unscoped, Latest draws on every library")
    }

    /// Both libraries' items in one order, newest first (Benjamin,
    /// 2026-10-16). A show Latest groups is dated by its newest episode
    /// (`DateLastMediaAdded`), not when the show itself was added.
    func test_recentlyAdded_isNewestFirstAcrossLibraries_datingAShowByItsNewestEpisode() async {
        let libraries = [
            Self.library("movies", collectionType: JellyfinCollectionType.movies),
            Self.library("shows", collectionType: JellyfinCollectionType.tvShows)
        ]
        var oldMovie = Self.backdropped("oldMovie", .movie)
        oldMovie.dateCreated = Self.date("2020-01-01")
        var newMovie = Self.backdropped("newMovie", .movie)
        newMovie.dateCreated = Self.date("2025-06-01")
        var showWithNewEpisodes = Self.backdropped("show", .series)
        showWithNewEpisodes.dateCreated = Self.date("2019-01-01")
        showWithNewEpisodes.dateLastMediaAdded = Self.date("2026-01-01")
        var loneEpisode = Self.backdropped("episode", .episode)
        loneEpisode.dateCreated = Self.date("2024-01-01")
        let latestByLibrary = ["movies": [newMovie, oldMovie], "shows": [showWithNewEpisodes, loneEpisode]]
        var latestFields: [String] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path.hasSuffix("/Items/Latest") {
                latestFields.append(request.queryDictionary["Fields"] ?? "")
                let parent = request.queryDictionary["ParentId"]
                return try MockURLProtocol.encodedJSONResponse(for: request, value: parent.flatMap { latestByLibrary[$0] } ?? [])
            }
            let items = url.path.hasSuffix("/Views") ? libraries : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(entries.map(\.id), ["show", "newMovie", "episode", "oldMovie"])
        XCTAssertTrue(latestFields.allSatisfy { $0.contains("DateCreated") && $0.contains("DateLastMediaAdded") },
                      "Jellyfin sends neither date unless asked")
    }

    private static func date(_ day: String) -> Date {
        ISO8601DateFormatter().date(from: day + "T00:00:00Z")!
    }

    func test_noMoviesOrShowsLibrary_asksNoLatest() async {
        var latestRequests = 0
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Items/Latest") {
                latestRequests += 1
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [Self.backdropped("album", .movie)])
            }
            let items = path.hasSuffix("/Views") ? [Self.library("music", collectionType: JellyfinCollectionType.music)] : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(latestRequests, 0)
    }

    private static func library(_ id: String, collectionType: String) -> BaseItemDto {
        var library = BaseItemDto(id: id, name: id, type: .collectionFolder)
        library.collectionType = collectionType
        return library
    }

    private static func backdropped(_ id: String, _ type: BaseItemKind) -> BaseItemDto {
        var item = BaseItemDto(id: id, name: id, type: type)
        item.backdropImageTags = ["t"]
        return item
    }
}
