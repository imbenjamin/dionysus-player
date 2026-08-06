import XCTest
@testable import Dionysus

/// `JellyfinAPIClient` is an actor that owns its own `URLSession`, so it
/// can't be swapped for a hand-written fake the way a protocol-backed
/// dependency could. Instead these tests inject a session wired to
/// `MockURLProtocol`, which is the same seam the app itself would use to
/// point at a real server — so what's under test is the real request
/// building, auth header, and decoding logic, not a reimplementation of it.
final class JellyfinAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(accessToken: String? = nil) -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: baseURL, accessToken: accessToken, session: MockURLProtocol.makeSession())
    }

    // MARK: Authentication

    func test_authenticate_postsToExpectedPathAndStoresAccessToken() async throws {
        let client = makeClient()
        let user = UserDto(id: "user-1", name: "ben")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/Users/AuthenticateByName")
            // Not yet signed in, so no token should be on the auth header.
            XCTAssertFalse((request.value(forHTTPHeaderField: "X-Emby-Authorization") ?? "").contains("Token="))

            let body = try JSONDecoder().decode([String: String].self, from: request.capturedHTTPBody ?? Data())
            XCTAssertEqual(body["Username"], "ben")
            XCTAssertEqual(body["Pw"], "hunter2")

            return try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: user, accessToken: "new-token", serverId: "server-1")
            )
        }

        let result = try await client.authenticate(username: "ben", password: "hunter2")
        XCTAssertEqual(result.accessToken, "new-token")
        let tokenAfterAuth = await client.accessToken
        XCTAssertEqual(tokenAfterAuth, "new-token")
    }

    func test_authenticate_wrongCredentials_throwsHTTPError() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 401, body: Data("Unauthorized".utf8))
        }

        do {
            _ = try await client.authenticate(username: "ben", password: "wrong")
            XCTFail("Expected authentication to throw")
        } catch let JellyfinAPIError.http(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Expected JellyfinAPIError.http, got \(error)")
        }
    }

    // MARK: Request construction

    func test_items_defaultQuery_isRecursiveSortedByNameAscending() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "tok")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(userID: "user-1")
        XCTAssertEqual(capturedQuery["Recursive"], "true")
        XCTAssertEqual(capturedQuery["SortBy"], "SortName")
        XCTAssertEqual(capturedQuery["SortOrder"], "Ascending")
        XCTAssertNil(capturedQuery["ParentId"])
        XCTAssertNil(capturedQuery["SearchTerm"])
    }

    func test_items_appliesOptionalFiltersWhenProvided() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(
            userID: "user-1", parentID: "parent-1", includeItemTypes: ["Movie", "Series"],
            searchTerm: "arrival", limit: 5
        )
        XCTAssertEqual(capturedQuery["ParentId"], "parent-1")
        XCTAssertEqual(capturedQuery["IncludeItemTypes"], "Movie,Series")
        XCTAssertEqual(capturedQuery["SearchTerm"], "arrival")
        XCTAssertEqual(capturedQuery["Limit"], "5")
    }

    /// `Genres`/`Studios` are pipe-delimited, unlike every other joined
    /// param on `items(...)` (`IncludeItemTypes`/`Filters` are
    /// comma-delimited) — confirmed against Jellyfin's real `ItemsController`.
    func test_items_appliesGenresAndStudiosWithPipeDelimiter() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(userID: "user-1", genres: ["Action", "Sci-Fi"], studios: ["Marvel Studios"])
        XCTAssertEqual(capturedQuery["Genres"], "Action|Sci-Fi")
        XCTAssertEqual(capturedQuery["Studios"], "Marvel Studios")
    }

    /// `PersonTypes` is comma-delimited — unlike `Genres`/`Studios` above,
    /// confirmed against the real `ItemsController` signature.
    func test_items_appliesPersonAndPersonTypes() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(userID: "user-1", person: "Tom Hanks", personTypes: ["Actor"])
        XCTAssertEqual(capturedQuery["Person"], "Tom Hanks")
        XCTAssertEqual(capturedQuery["PersonTypes"], "Actor")
    }

    func test_item_requestsDetailFieldsIncludingMediaSourcesAndPeople() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        let dto = BaseItemDto(id: "item-1", name: "Arrival", type: .movie)
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.url?.path, "/Users/user-1/Items/item-1")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: dto)
        }

        let result = try await client.item(userID: "user-1", itemID: "item-1")
        XCTAssertEqual(result.id, "item-1")
        XCTAssertTrue((capturedQuery["Fields"] ?? "").contains("MediaSources"))
        XCTAssertTrue((capturedQuery["Fields"] ?? "").contains("People"), "Cast & Crew tab needs this")
    }

    func test_decodingFailure_surfacesAsDecodingError() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, body: Data("{ not valid json".utf8))
        }

        do {
            _ = try await client.items(userID: "user-1")
            XCTFail("Expected a decoding error")
        } catch JellyfinAPIError.decoding {
            // expected
        } catch {
            XCTFail("Expected JellyfinAPIError.decoding, got \(error)")
        }
    }

    // MARK: streamURL (pure, no network)

    func test_streamURL_includesStaticFlagAndDeviceIdAlways() async {
        let client = makeClient()
        let url = await client.streamURL(itemID: "item-1", mediaSourceID: nil, container: nil)
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["Static"], "true")
        XCTAssertNotNil(query["DeviceId"])
        XCTAssertNil(query["MediaSourceId"])
        XCTAssertNil(query["Container"])
        XCTAssertNil(query["ApiKey"])
    }

    func test_streamURL_includesOptionalParamsAndApiKeyWhenSignedIn() async {
        let client = makeClient(accessToken: "tok")
        let url = await client.streamURL(itemID: "item-1", mediaSourceID: "src-1", container: "mkv")
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["MediaSourceId"], "src-1")
        XCTAssertEqual(query["Container"], "mkv")
        XCTAssertEqual(query["ApiKey"], "tok")
    }

    // MARK: makeImageURLBuilder

    func test_makeImageURLBuilder_snapshotsCurrentBaseURLAndToken() async {
        let client = makeClient(accessToken: "tok")
        let builder = await client.makeImageURLBuilder()
        XCTAssertEqual(builder.baseURL, baseURL)
        XCTAssertEqual(builder.accessToken, "tok")
    }

    // MARK: Playback progress reporting (no-content responses)

    private struct DecodedProgressBody: Decodable {
        let ItemId: String
        let PositionTicks: Int64
        let IsPaused: Bool
    }

    func test_reportPlaybackStopped_sendsPositionAndSucceedsOnNoContentResponse() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Sessions/Playing/Stopped")
            let body = try JSONDecoder().decode(DecodedProgressBody.self, from: request.capturedHTTPBody ?? Data())
            XCTAssertEqual(body.ItemId, "item-1")
            XCTAssertEqual(body.PositionTicks, 12_345)
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        try await client.reportPlaybackStopped(itemID: "item-1", positionTicks: 12_345)
    }

    func test_reportPlaybackProgress_serverError_throwsHTTPError() async {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        do {
            try await client.reportPlaybackProgress(itemID: "item-1", positionTicks: 0, isPaused: false)
            XCTFail("Expected a thrown error")
        } catch let JellyfinAPIError.http(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Expected JellyfinAPIError.http, got \(error)")
        }
    }

    // MARK: Genres & Studios (Home's dynamic rail discovery)

    func test_genres_requestsExpectedPathAndScopesByIncludeItemTypes() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        let action = BaseItemDto(id: "genre-1", name: "Action", type: .unknown)
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.url?.path, "/Genres")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [action], totalRecordCount: 1))
        }

        let result = try await client.genres(userID: "user-1", includeItemTypes: ["Movie"])
        XCTAssertEqual(result.items.map(\.name), ["Action"])
        XCTAssertEqual(capturedQuery["userId"], "user-1")
        XCTAssertEqual(capturedQuery["IncludeItemTypes"], "Movie")
    }

    func test_studios_requestsExpectedPathAndScopesByIncludeItemTypes() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        let hbo = BaseItemDto(id: "studio-1", name: "HBO", type: .unknown)
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.url?.path, "/Studios")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [hbo], totalRecordCount: 1))
        }

        let result = try await client.studios(userID: "user-1", includeItemTypes: ["Series"])
        XCTAssertEqual(result.items.map(\.name), ["HBO"])
        XCTAssertEqual(capturedQuery["userId"], "user-1")
        XCTAssertEqual(capturedQuery["IncludeItemTypes"], "Series")
    }

    func test_persons_requestsExpectedPathAndScopesByPersonTypes() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        let tomHanks = BaseItemDto(id: "person-1", name: "Tom Hanks", type: .unknown)
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.url?.path, "/Persons")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [tomHanks], totalRecordCount: 1))
        }

        let result = try await client.persons(userID: "user-1", personTypes: ["Actor"])
        XCTAssertEqual(result.items.map(\.name), ["Tom Hanks"])
        XCTAssertEqual(capturedQuery["userId"], "user-1")
        XCTAssertEqual(capturedQuery["personTypes"], "Actor")
    }

    // MARK: collectionsContaining — exercises the fan-out/task-group logic

    func test_collectionsContaining_returnsOnlyBoxSetsThatContainTheItem() async throws {
        let client = makeClient(accessToken: "tok")
        let matchingBoxSet = BaseItemDto(id: "boxset-yes", name: "Matches", type: .boxSet)
        let otherBoxSet = BaseItemDto(id: "boxset-no", name: "Doesn't match", type: .boxSet)
        let targetItem = BaseItemDto(id: "item-1", name: "Arrival", type: .movie)

        MockURLProtocol.requestHandler = { request in
            let query = request.queryDictionary
            if query["IncludeItemTypes"] == "BoxSet" {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: BaseItemDtoQueryResult(items: [matchingBoxSet, otherBoxSet], totalRecordCount: 2)
                )
            }
            // Per-BoxSet membership lookup, keyed by ParentId.
            let children = query["ParentId"] == "boxset-yes" ? [targetItem] : []
            return try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: BaseItemDtoQueryResult(items: children, totalRecordCount: children.count)
            )
        }

        let matches = try await client.collectionsContaining(itemID: "item-1", userID: "user-1")
        XCTAssertEqual(matches.map(\.id), ["boxset-yes"])
    }

    func test_collectionsContaining_noBoxSetsAtAll_skipsMembershipLookupsAndReturnsEmpty() async throws {
        let client = makeClient(accessToken: "tok")
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        let matches = try await client.collectionsContaining(itemID: "item-1", userID: "user-1")
        XCTAssertEqual(matches, [])
        XCTAssertEqual(requestCount, 1, "Should short-circuit after the empty BoxSet lookup instead of firing per-BoxSet requests")
    }
}
