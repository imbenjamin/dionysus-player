import XCTest
@testable import Dionysus

/// `JellyfinAPIClient` is an actor that owns its own `URLSession`, so it
/// can't be swapped for a hand-written fake the way a protocol-backed
/// dependency could. Instead these tests inject a session wired to
/// `MockURLProtocol`, which is the same seam the app itself would use to
/// point at a real server — so what's under test is the real request
/// building, auth header, and decoding logic, not a reimplementation of it.
@MainActor
final class JellyfinAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        // Process-wide singleton, same cross-test-pollution risk
        // `MockURLProtocol.reset()` above already guards against.
        ConnectivityMonitor.shared.reset()
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

    // MARK: 401 auto re-authentication
    //
    // Confirmed live (2026-08-22) against a heavily-shared public demo
    // server: a session token this client was issued can be invalidated
    // server-side with no action by this app at all. `sendRaw`'s 401
    // handling tries to recover from that transparently — see its own doc
    // comment for the full reasoning; these tests pin the observable
    // behavior. `authenticate(...)`'s own 401 (a wrong password at first
    // sign-in) staying a raw `.http` error is covered separately by
    // `test_authenticate_wrongCredentials_throwsHTTPError` above — that
    // request never carries an `X-Emby-Token` header, so it never reaches
    // any of this.

    /// A single 401 recovers with no visible error and no artificial delay
    /// (the first retry attempt, `attempt == 0`, skips the backoff sleep —
    /// see `reauthenticate(using:attempt:)`) — the request that triggered
    /// it just succeeds once retried with the fresh token.
    func test_401_singleFailure_reauthenticatesAndRetriesTransparently() async throws {
        let client = makeClient()
        _ = try await authenticateSuccessfully(client, token: "token-1")

        var viewsRequestCount = 0
        var capturedRetryToken: String?
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Views":
                viewsRequestCount += 1
                if viewsRequestCount == 1 {
                    return MockURLProtocol.jsonResponse(for: request, status: 401, body: Self.jellyfinHTML401Body)
                }
                capturedRetryToken = request.value(forHTTPHeaderField: "X-Emby-Token")
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/AuthenticateByName":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: AuthenticationResult(user: UserDto(id: "user-1", name: "demo"), accessToken: "token-2")
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        _ = try await client.userViews(userID: "user-1")

        XCTAssertEqual(viewsRequestCount, 2)
        XCTAssertEqual(capturedRetryToken, "token-2")
        let tokenAfterRecovery = await client.accessToken
        XCTAssertEqual(tokenAfterRecovery, "token-2")
    }

    /// Every attempt (the original request and every retry) keeps 401ing —
    /// the backoff schedule eventually runs out and this surfaces as
    /// `.notAuthenticated`, a clean "you need to sign in again" rather than
    /// the raw HTML the server's own 401 page carries.
    func test_401_reauthenticationExhausted_throwsNotAuthenticated() async throws {
        let client = makeClient()
        _ = try await authenticateSuccessfully(client, token: "token-1")

        var viewsRequestCount = 0
        var reauthRequestCount = 0
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Views":
                viewsRequestCount += 1
                return MockURLProtocol.jsonResponse(for: request, status: 401, body: Self.jellyfinHTML401Body)
            case "/Users/AuthenticateByName":
                reauthRequestCount += 1
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: AuthenticationResult(user: UserDto(id: "user-1", name: "demo"), accessToken: "token-\(reauthRequestCount + 1)")
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        do {
            _ = try await client.userViews(userID: "user-1")
            XCTFail("Expected .notAuthenticated")
        } catch JellyfinAPIError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }

        // One original attempt plus one retry per backoff-schedule entry.
        XCTAssertEqual(viewsRequestCount, 5)
        XCTAssertEqual(reauthRequestCount, 4)
    }

    /// No prior successful `authenticate(...)` call means nothing to retry
    /// with — a 401 in that state (e.g. a token injected directly, as every
    /// other test in this file does via `makeClient(accessToken:)`) fails
    /// fast as `.notAuthenticated` rather than attempting to reauthenticate
    /// with credentials it doesn't have.
    func test_401_noRememberedCredentials_throwsNotAuthenticatedImmediately() async throws {
        let client = makeClient(accessToken: "injected-token")
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Self.jellyfinHTML401Body)
        }

        do {
            _ = try await client.userViews(userID: "user-1")
            XCTFail("Expected .notAuthenticated")
        } catch JellyfinAPIError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }
        XCTAssertEqual(requestCount, 1, "nothing to retry with, so this shouldn't have attempted a reauth/retry at all")
    }

    /// Several requests 401ing around the same moment (e.g. `HomeViewModel
    /// .load()`'s multi-endpoint fan-out) must coalesce into a single
    /// re-authentication rather than each racing to hit
    /// `/Users/AuthenticateByName` independently.
    func test_401_concurrentFailures_coalesceIntoASingleReauthentication() async throws {
        let client = makeClient()
        _ = try await authenticateSuccessfully(client, token: "token-1")

        let viewsCounter = RequestCounter()
        let reauthCounter = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Views":
                let count = viewsCounter.increment()
                if count <= 3 {
                    return MockURLProtocol.jsonResponse(for: request, status: 401, body: Self.jellyfinHTML401Body)
                }
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
            case "/Users/AuthenticateByName":
                reauthCounter.increment()
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: AuthenticationResult(user: UserDto(id: "user-1", name: "demo"), accessToken: "token-2")
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        async let first = client.userViews(userID: "user-1")
        async let second = client.userViews(userID: "user-1")
        async let third = client.userViews(userID: "user-1")
        _ = try await (first, second, third)

        XCTAssertEqual(reauthCounter.count, 1, "three concurrent 401s should share one reauthentication, not each trigger their own")
    }

    private static let jellyfinHTML401Body = Data("""
    <html><body>Unauthorized (HTTP 401): Request not authorized; please log in first.</body></html>
    """.utf8)

    @discardableResult
    private func authenticateSuccessfully(_ client: JellyfinAPIClient, token: String) async throws -> AuthenticationResult {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "demo"), accessToken: token)
            )
        }
        return try await client.authenticate(username: "demo", password: "")
    }

    // MARK: ConnectivityMonitor reporting

    func test_transportFailure_reportsOffline() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await client.publicSystemInfo()
            XCTFail("Expected the transport error to propagate")
        } catch {
            // expected — URLError propagates unwrapped, see sendRaw's doc comment
        }
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline)
    }

    /// A real HTTP response — success or an error status — means the
    /// server was reachable, so it must never be treated as offline.
    func test_httpErrorResponse_doesNotReportOffline() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        do {
            _ = try await client.publicSystemInfo()
            XCTFail("Expected the HTTP error to propagate")
        } catch {
            // expected
        }
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
    }

    func test_healthCheck_hitsHealthEndpointUnauthenticated() async throws {
        let client = makeClient()
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("Healthy".utf8))
        }

        try await client.healthCheck()

        XCTAssertEqual(capturedRequest?.url?.path, "/health")
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
    }

    func test_successfulResponse_afterAPriorFailure_clearsOffline() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        _ = try? await client.publicSystemInfo()
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline)

        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo())
        }
        _ = try? await client.publicSystemInfo()
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
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

    /// AUDIO SUPPRESSION: `excludeItemTypes`/`mediaTypes` back `JellyfinAPIClient
    /// .audioItemTypeExclusions`'s use in `HomeViewModel`/`CollectionGridViewModel`.
    func test_items_appliesExcludeItemTypesAndMediaTypesWhenProvided() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(userID: "user-1", excludeItemTypes: ["Audio", "MusicAlbum"], mediaTypes: ["Video"])
        XCTAssertEqual(capturedQuery["ExcludeItemTypes"], "Audio,MusicAlbum")
        XCTAssertEqual(capturedQuery["MediaTypes"], "Video")
    }

    func test_items_omitsExcludeItemTypesAndMediaTypesWhenEmpty() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.items(userID: "user-1")
        XCTAssertNil(capturedQuery["ExcludeItemTypes"])
        XCTAssertNil(capturedQuery["MediaTypes"])
    }

    // MARK: resumeItems

    func test_resumeItems_appliesExcludeItemTypesWhenProvided() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.resumeItems(userID: "user-1", excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions)
        XCTAssertEqual(capturedQuery["ExcludeItemTypes"], "Audio,AudioBook,MusicAlbum,MusicArtist,MusicGenre")
    }

    func test_resumeItems_omitsExcludeItemTypesWhenEmpty() async throws {
        let client = makeClient()
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.resumeItems(userID: "user-1")
        XCTAssertNil(capturedQuery["ExcludeItemTypes"])
    }

    // MARK: searchHints

    func test_searchHints_hitsTheDedicatedEndpointWithExpectedQuery() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            XCTAssertEqual(request.url?.path, "/Search/Hints")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: SearchHintResult(searchHints: [], totalRecordCount: 0))
        }

        _ = try await client.searchHints(userID: "user-1", term: "arrival", limit: 8)
        XCTAssertEqual(capturedQuery["searchTerm"], "arrival")
        XCTAssertEqual(capturedQuery["userId"], "user-1")
        XCTAssertEqual(capturedQuery["limit"], "8")
        XCTAssertEqual(capturedQuery["includeItemTypes"], "Movie,Series,Episode,BoxSet")
    }

    func test_searchHints_decodesResultFields() async throws {
        let client = makeClient()
        let hint = SearchHint(
            id: "episode-1", name: "Pilot", type: .episode, productionYear: 2019, series: "Arrival Series",
            primaryImageTag: "tag-1", thumbImageTag: "thumb-1", thumbImageItemId: "series-1"
        )
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: SearchHintResult(searchHints: [hint], totalRecordCount: 1))
        }

        let result = try await client.searchHints(userID: "user-1", term: "pilot")
        XCTAssertEqual(result.searchHints, [hint])
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
        XCTAssertTrue((capturedQuery["Fields"] ?? "").contains("Taglines"), "About tab's tagline needs this")
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

    // MARK: subtitleURL (pure, no network)

    func test_subtitleURL_buildsWellKnownRouteWithNoApiKeyWhenSignedOut() async {
        let client = makeClient()
        let url = await client.subtitleURL(itemID: "item-1", mediaSourceID: "src-1", streamIndex: 3, codec: "subrip")
        XCTAssertEqual(url?.path, "/Videos/item-1/src-1/Subtitles/3/Stream.srt")
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertNil(query["ApiKey"])
    }

    func test_subtitleURL_includesApiKeyWhenSignedIn() async {
        let client = makeClient(accessToken: "tok")
        let url = await client.subtitleURL(itemID: "item-1", mediaSourceID: "src-1", streamIndex: 3, codec: "subrip")
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["ApiKey"], "tok")
    }

    /// The extension has to match the stream's own codec (ass/ssa/vtt) so
    /// Jellyfin serves the sidecar file byte-for-byte rather than
    /// server-side converting it — anything else, including an absent
    /// codec, falls back to "srt", the most common external format.
    func test_subtitleURL_derivesFileExtensionFromCodec() async {
        let client = makeClient()
        let cases: [(String?, String)] = [("subrip", "srt"), ("ass", "ass"), ("ssa", "ssa"), ("webvtt", "vtt"), (nil, "srt"), ("mystery", "srt")]
        for (codec, expectedExtension) in cases {
            let url = await client.subtitleURL(itemID: "item-1", mediaSourceID: "src-1", streamIndex: 0, codec: codec)
            XCTAssertEqual(url?.path, "/Videos/item-1/src-1/Subtitles/0/Stream.\(expectedExtension)", "codec \(codec ?? "nil")")
        }
    }

    // MARK: isImageBasedSubtitleCodec (pure, no network)

    func test_isImageBasedSubtitleCodec_recognizesBitmapFormats() {
        for codec in ["pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub", "PGSSUB"] {
            XCTAssertTrue(JellyfinAPIClient.isImageBasedSubtitleCodec(codec), "expected \(codec) to be image-based")
        }
    }

    func test_isImageBasedSubtitleCodec_falseForTextFormatsAndNil() {
        for codec: String? in ["subrip", "ass", "ssa", "webvtt", nil, "mystery"] {
            XCTAssertFalse(JellyfinAPIClient.isImageBasedSubtitleCodec(codec), "expected \(codec ?? "nil") to not be image-based")
        }
    }

    // MARK: downloadStreamURL (pure, no network)

    func test_downloadStreamURL_alwaysTranscodesToHEVCMp4Stereo() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(url?.path, "/Videos/item-1/stream.mp4")
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["Static"], "false")
        XCTAssertEqual(query["Container"], "mp4")
        XCTAssertEqual(query["VideoCodec"], "hevc")
        XCTAssertEqual(query["AudioCodec"], "aac")
        XCTAssertEqual(query["MaxAudioChannels"], "2")
        XCTAssertNotNil(query["DeviceId"])
    }

    func test_downloadStreamURL_capsResolutionAndBitrateToTierWhenSourceIsLarger() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: "src-1", audioStreamIndex: 2,
            resolution: .hd1080p, preset: .high, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 50_000_000
        )
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["MaxWidth"], "1920")
        XCTAssertEqual(query["MaxHeight"], "1080")
        XCTAssertEqual(query["VideoBitrate"], "4500000")
        XCTAssertEqual(query["AudioBitrate"], "160000")
        XCTAssertEqual(query["MediaSourceId"], "src-1")
        XCTAssertEqual(query["AudioStreamIndex"], "2")
    }

    /// Never upscale/inflate: a source below the requested tier keeps its
    /// own (lower) dimensions/bitrate rather than being padded up to the
    /// tier's max.
    func test_downloadStreamURL_neverExceedsSourceWhenSourceIsSmaller() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .uhd4K, preset: .high, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 2_000_000
        )
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["MaxWidth"], "1280")
        XCTAssertEqual(query["MaxHeight"], "720")
        XCTAssertEqual(query["VideoBitrate"], "2000000")
    }

    /// `main10` for SDR sources too, not just HDR ones — 10-bit HEVC is
    /// more efficient at any source bit depth.
    func test_downloadStreamURL_alwaysRequestsMain10Profile() async {
        let client = makeClient()
        for isSourceHDR in [true, false] {
            let url = await client.downloadStreamURL(
                itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
                resolution: .hd1080p, preset: .normal, isSourceHDR: isSourceHDR,
                sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
            )
            XCTAssertEqual(URLRequest(url: url!).queryDictionary["VideoProfile"], "main10")
        }
    }

    /// Only Data Saver sends a frame-rate cap; the other presets omit the
    /// param entirely rather than sending a permissive value.
    func test_downloadStreamURL_sendsMaxFramerateOnlyForDataSaver() async {
        let client = makeClient()
        let dataSaverURL = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd720p, preset: .dataSaver, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(URLRequest(url: dataSaverURL!).queryDictionary["MaxFramerate"], "30")

        let normalURL = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertNil(URLRequest(url: normalURL!).queryDictionary["MaxFramerate"])
    }

    /// A source already inside the tier asks Jellyfin to copy the video
    /// track rather than re-encode it. Two things this pins, both learned
    /// from probing a real server:
    ///
    /// - `VideoCodec` must *include the source's own codec*, or Jellyfin
    ///   silently declines the copy.
    /// - The resolution/bitrate caps are still sent. Jellyfin ignores them
    ///   when it copies, and they're the only bound on the fallback if it
    ///   doesn't — dropping them turned a 1280×720 source into a 416×234,
    ///   343 Kbps file in live testing.
    func test_downloadStreamURL_streamCopiesVideoWhenSourceAlreadyFitsTier() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 1_200_000,
            sourceVideoCodec: "h264"
        )
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["AllowVideoStreamCopy"], "true")
        XCTAssertEqual(query["VideoCodec"], "hevc,h264", "source codec must be offered or the copy is declined")
        XCTAssertEqual(query["MaxWidth"], "1280", "caps stay as a bound on a declined-copy fallback")
        XCTAssertEqual(query["MaxHeight"], "720")
        XCTAssertEqual(query["VideoBitrate"], "1200000")
        // Audio is still transcoded either way, so the output keeps the
        // MP4/AAC-stereo shape the offline path assumes.
        XCTAssertEqual(query["AudioCodec"], "aac")
        XCTAssertEqual(query["MaxAudioChannels"], "2")
        XCTAssertEqual(query["AudioBitrate"], "128000")
    }

    /// An HEVC source doesn't get a redundant second entry in `VideoCodec`.
    func test_downloadStreamURL_streamCopyOfHevcSource_doesNotDuplicateCodec() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: 1920, sourceHeight: 1080, sourceBitrate: 2_500_000,
            sourceVideoCodec: "hevc"
        )
        XCTAssertEqual(URLRequest(url: url!).queryDictionary["VideoCodec"], "hevc")
    }

    /// The ordinary transcode path asks for HEVC and nothing else.
    func test_downloadStreamURL_requestsHevcOnlyWhenNotStreamCopying() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 30_000_000,
            sourceVideoCodec: "h264"
        )
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertEqual(query["VideoCodec"], "hevc")
        XCTAssertNil(query["AllowVideoStreamCopy"])
    }

    /// An HDR source is never stream-copied, even when it otherwise fits:
    /// a copy would preserve HDR that `DownloadedItem.isHDR` reports as
    /// tone-mapped away.
    func test_downloadStreamURL_doesNotStreamCopyHDRSource() async {
        let client = makeClient()
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd720p, preset: .normal, isSourceHDR: true,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 1_200_000,
            sourceVideoCodec: "hevc"
        )
        let query = URLRequest(url: url!).queryDictionary
        XCTAssertNil(query["AllowVideoStreamCopy"])
        XCTAssertEqual(query["VideoBitrate"], "1200000")
    }

    func test_downloadStreamURL_includesApiKeyWhenSignedIn() async {
        let client = makeClient(accessToken: "tok")
        let url = await client.downloadStreamURL(
            itemID: "item-1", mediaSourceID: nil, audioStreamIndex: nil,
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(URLRequest(url: url!).queryDictionary["ApiKey"], "tok")
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

    /// The active session should reflect which version is actually
    /// streaming (see `PlayerViewModel.activeMediaSourceID`'s doc comment),
    /// not just the item — checked once here for `reportPlaybackStopped`;
    /// `reportPlaybackStart`/`reportPlaybackProgress` share the exact same
    /// `PlaybackProgressRequest` encoding.
    func test_reportPlaybackStopped_includesMediaSourceIdWhenProvided() async throws {
        let client = makeClient(accessToken: "tok")
        struct DecodedBodyWithSource: Decodable { let MediaSourceId: String? }
        var decoded: DecodedBodyWithSource?
        MockURLProtocol.requestHandler = { request in
            decoded = try JSONDecoder().decode(DecodedBodyWithSource.self, from: request.capturedHTTPBody ?? Data())
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        try await client.reportPlaybackStopped(itemID: "item-1", positionTicks: 12_345, mediaSourceID: "src-1080p")

        XCTAssertEqual(decoded?.MediaSourceId, "src-1080p")
    }

    // MARK: updateUserData (offline sync — no active-session requirement)

    func test_updateUserData_sendsPositionPlayedAndPercentage() async throws {
        let client = makeClient(accessToken: "tok")
        struct DecodedBody: Decodable { let PlaybackPositionTicks: Int64; let Played: Bool; let PlayedPercentage: Double }
        var decoded: DecodedBody?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Users/user-1/Items/item-1/UserData")
            XCTAssertEqual(request.httpMethod, "POST")
            decoded = try JSONDecoder().decode(DecodedBody.self, from: request.capturedHTTPBody ?? Data())
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        try await client.updateUserData(itemID: "item-1", userID: "user-1", positionTicks: 98_765, isPlayed: true, playedPercentage: 87.5)

        XCTAssertEqual(decoded?.PlaybackPositionTicks, 98_765)
        XCTAssertEqual(decoded?.Played, true)
        XCTAssertEqual(decoded?.PlayedPercentage, 87.5)
    }

    func test_playbackInfo_includesMediaSourceIdInRequestBodyWhenProvided() async throws {
        let client = makeClient(accessToken: "tok")
        struct DecodedPlaybackInfoBody: Decodable { let UserId: String; let MediaSourceId: String? }
        var decoded: DecodedPlaybackInfoBody?
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Items/item-1/PlaybackInfo")
            decoded = try JSONDecoder().decode(DecodedPlaybackInfoBody.self, from: request.capturedHTTPBody ?? Data())
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse())
        }

        _ = try await client.playbackInfo(itemID: "item-1", userID: "user-1", mediaSourceID: "src-1080p")

        XCTAssertEqual(decoded?.UserId, "user-1")
        XCTAssertEqual(decoded?.MediaSourceId, "src-1080p")
    }

    func test_playbackInfo_omitsMediaSourceIdWhenNotProvided() async throws {
        let client = makeClient(accessToken: "tok")
        struct DecodedPlaybackInfoBody: Decodable { let MediaSourceId: String? }
        var decoded: DecodedPlaybackInfoBody?
        MockURLProtocol.requestHandler = { request in
            decoded = try JSONDecoder().decode(DecodedPlaybackInfoBody.self, from: request.capturedHTTPBody ?? Data())
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse())
        }

        _ = try await client.playbackInfo(itemID: "item-1", userID: "user-1")

        XCTAssertNil(decoded?.MediaSourceId)
    }

    func test_currentSession_filtersByDeviceIdAndReturnsFirstMatch() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Sessions")
            XCTAssertEqual(request.queryDictionary["DeviceId"], "device-1")
            let session = SessionInfoDto(
                id: "sess-1", deviceId: "device-1",
                playState: PlayStateInfoDto(mediaSourceId: "src-1", playMethod: "Transcode"),
                transcodingInfo: TranscodingInfoDto(videoCodec: "h264")
            )
            return try MockURLProtocol.encodedJSONResponse(for: request, value: [session])
        }

        let session = try await client.currentSession(deviceID: "device-1")

        XCTAssertEqual(session?.playState?.playMethod, "Transcode")
        XCTAssertEqual(session?.transcodingInfo?.videoCodec, "h264")
    }

    func test_currentSession_noActiveSession_returnsNil() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: [SessionInfoDto]())
        }

        let session = try await client.currentSession(deviceID: "device-1")

        XCTAssertNil(session)
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

    // MARK: Favorite / watched status

    func test_setFavorite_true_postsToFavoriteItemsPath() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/Users/user-1/FavoriteItems/item-1")
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
        }

        try await client.setFavorite(true, itemID: "item-1", userID: "user-1")
    }

    func test_setFavorite_false_deletesFromFavoriteItemsPath() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/Users/user-1/FavoriteItems/item-1")
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
        }

        try await client.setFavorite(false, itemID: "item-1", userID: "user-1")
    }

    func test_setWatched_true_postsToPlayedItemsPath() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/Users/user-1/PlayedItems/item-1")
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
        }

        try await client.setWatched(true, itemID: "item-1", userID: "user-1")
    }

    func test_setWatched_false_deletesFromPlayedItemsPath() async throws {
        let client = makeClient(accessToken: "tok")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/Users/user-1/PlayedItems/item-1")
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data("{}".utf8))
        }

        try await client.setWatched(false, itemID: "item-1", userID: "user-1")
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

    /// `limit` is what keeps Home's actor/director discovery from fetching
    /// a library's entire cast/crew corpus (unlike genres/studios, which
    /// have no equivalent param since their counts are naturally small) —
    /// worth its own check that it's actually wired through, since it
    /// defaults to `nil`/omitted for other callers of this same method.
    func test_persons_appliesLimitWhenProvided() async throws {
        let client = makeClient(accessToken: "tok")
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedQuery = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.persons(userID: "user-1", personTypes: ["Actor"], limit: 200)
        XCTAssertEqual(capturedQuery["Limit"], "200")
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

    /// Each per-BoxSet membership check only needs `id` to decide a match —
    /// none of `defaultFields`' heavier payload (Overview/Genres/Studios/
    /// ...), which used to be fetched and immediately discarded for every
    /// item in every collection.
    func test_collectionsContaining_membershipLookupOmitsFieldsParam() async throws {
        let client = makeClient(accessToken: "tok")
        let boxSet = BaseItemDto(id: "boxset-1", name: "A Collection", type: .boxSet)
        nonisolated(unsafe) var membershipLookupQuery: [String: String]?

        MockURLProtocol.requestHandler = { request in
            let query = request.queryDictionary
            if query["IncludeItemTypes"] == "BoxSet" {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [boxSet], totalRecordCount: 1)
                )
            }
            membershipLookupQuery = query
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        _ = try await client.collectionsContaining(itemID: "item-1", userID: "user-1")
        XCTAssertNil(membershipLookupQuery?["Fields"])
    }

    /// A single BoxSet's membership check hiccupping (a transport error,
    /// standing in for anything from a dropped connection to a slow one
    /// among many in flight) shouldn't fail the *entire* call — every other
    /// BoxSet's own check should still run and still count, and the failed
    /// one should just read as "not a match" rather than aborting
    /// everything. This is what `load()` (`AssetDetailViewModel`) relies on
    /// to keep a single flaky collection check from blanking the whole
    /// detail page.
    func test_collectionsContaining_oneFailingMembershipLookup_stillReturnsTheOthers() async throws {
        let client = makeClient(accessToken: "tok")
        let failingBoxSet = BaseItemDto(id: "boxset-fails", name: "Flaky", type: .boxSet)
        let matchingBoxSet = BaseItemDto(id: "boxset-matches", name: "Fine", type: .boxSet)
        let targetItem = BaseItemDto(id: "item-1", name: "Arrival", type: .movie)

        MockURLProtocol.requestHandler = { request in
            let query = request.queryDictionary
            if query["IncludeItemTypes"] == "BoxSet" {
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: BaseItemDtoQueryResult(items: [failingBoxSet, matchingBoxSet], totalRecordCount: 2)
                )
            }
            if query["ParentId"] == "boxset-fails" {
                throw URLError(.networkConnectionLost)
            }
            let children = query["ParentId"] == "boxset-matches" ? [targetItem] : []
            return try MockURLProtocol.encodedJSONResponse(
                for: request, value: BaseItemDtoQueryResult(items: children, totalRecordCount: children.count)
            )
        }

        let matches = try await client.collectionsContaining(itemID: "item-1", userID: "user-1")
        XCTAssertEqual(matches.map(\.id), ["boxset-matches"])
    }

    // MARK: nextEpisode — unlike nextUp(userID:seriesID:), works regardless of watched state

    func test_nextEpisode_sameSeason_returnsFollowingIndexNumber() async throws {
        let client = makeClient(accessToken: "tok")
        let episodes = [
            BaseItemDto(id: "ep-1", name: "One", type: .episode, indexNumber: 1),
            BaseItemDto(id: "ep-2", name: "Two", type: .episode, indexNumber: 2),
            BaseItemDto(id: "ep-3", name: "Three", type: .episode, indexNumber: 3)
        ]
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Shows/series-1/Episodes")
            XCTAssertEqual(request.queryDictionary["seasonId"], "season-1")
            return try MockURLProtocol.encodedJSONResponse(
                for: request, value: BaseItemDtoQueryResult(items: episodes, totalRecordCount: episodes.count)
            )
        }

        let next = try await client.nextEpisode(currentEpisodeID: "ep-1", seriesID: "series-1", seasonID: "season-1", userID: "user-1")
        XCTAssertEqual(next?.id, "ep-2")
    }

    func test_nextEpisode_lastInSeason_crossesToFirstEpisodeOfNextSeason() async throws {
        let client = makeClient(accessToken: "tok")
        let season1Episodes = [BaseItemDto(id: "ep-1", name: "One", type: .episode, indexNumber: 1)]
        let season2Episodes = [
            BaseItemDto(id: "ep-2-1", name: "Two One", type: .episode, indexNumber: 1),
            BaseItemDto(id: "ep-2-2", name: "Two Two", type: .episode, indexNumber: 2)
        ]
        let seasons = [
            BaseItemDto(id: "season-1", name: "Season 1", type: .season, indexNumber: 1),
            BaseItemDto(id: "season-2", name: "Season 2", type: .season, indexNumber: 2)
        ]
        MockURLProtocol.requestHandler = { request in
            switch (request.url?.path, request.queryDictionary["seasonId"]) {
            case ("/Shows/series-1/Episodes", "season-1"):
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: season1Episodes, totalRecordCount: season1Episodes.count)
                )
            case ("/Shows/series-1/Episodes", "season-2"):
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: season2Episodes, totalRecordCount: season2Episodes.count)
                )
            case ("/Shows/series-1/Seasons", _):
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: seasons, totalRecordCount: seasons.count)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                throw MockURLProtocol.UnhandledRequest()
            }
        }

        let next = try await client.nextEpisode(currentEpisodeID: "ep-1", seriesID: "series-1", seasonID: "season-1", userID: "user-1")
        XCTAssertEqual(next?.id, "ep-2-1")
    }

    func test_nextEpisode_lastEpisodeOfSeries_returnsNil() async throws {
        let client = makeClient(accessToken: "tok")
        let onlySeasonEpisodes = [BaseItemDto(id: "ep-1", name: "One", type: .episode, indexNumber: 1)]
        let onlySeason = [BaseItemDto(id: "season-1", name: "Season 1", type: .season, indexNumber: 1)]
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Shows/series-1/Episodes":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: onlySeasonEpisodes, totalRecordCount: onlySeasonEpisodes.count)
                )
            case "/Shows/series-1/Seasons":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: onlySeason, totalRecordCount: onlySeason.count)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                throw MockURLProtocol.UnhandledRequest()
            }
        }

        let next = try await client.nextEpisode(currentEpisodeID: "ep-1", seriesID: "series-1", seasonID: "season-1", userID: "user-1")
        XCTAssertNil(next)
    }
}

/// Thread-safe request counter — `MockURLProtocol.requestHandler` runs on
/// whatever background queue the URL Loading System chooses, and the 401
/// coalescing test above deliberately issues concurrent requests, so a
/// plain `var` isn't safe here. Same shape as `RemoteImageLoaderTests`'
/// own private `RequestCounter` — duplicated rather than shared since
/// Swift's top-level `private` scopes it to that file.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
