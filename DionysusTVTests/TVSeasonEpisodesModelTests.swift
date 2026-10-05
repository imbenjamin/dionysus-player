import XCTest
@testable import Dionysus

@MainActor
final class TVSeasonEpisodesModelTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeModel() -> TVSeasonEpisodesModel {
        let client = JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession())
        return TVSeasonEpisodesModel(client: client, userID: "user-1", seriesID: "series-1")
    }

    nonisolated private static func episodesResponse(_ request: URLRequest, _ ids: [String]) throws -> (HTTPURLResponse, Data) {
        let items = ids.map { BaseItemDto(id: $0, name: $0, type: .episode) }
        return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
    }

    func test_load_fetchesOneSeason_once() async throws {
        nonisolated(unsafe) var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            XCTAssertTrue(request.url?.query?.contains("seasonId=s1") ?? false)
            return try Self.episodesResponse(request, ["e1", "e2"])
        }
        let model = makeModel()
        await model.load(seasonID: "s1")
        await model.load(seasonID: "s1")
        XCTAssertEqual(model.episodes["s1"]?.map(\.id), ["e1", "e2"])
        XCTAssertEqual(requests, 1, "A season already loaded isn't fetched again")
    }

    func test_forcedLoad_refetches() async throws {
        nonisolated(unsafe) var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try Self.episodesResponse(request, ["e1"])
        }
        let model = makeModel()
        await model.load(seasonID: "s1")
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(requests, 2)
    }

    /// A season that exists with no episodes is an empty list, not a failure.
    func test_emptySeason_isLoadedAndEmpty() async throws {
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, []) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        XCTAssertEqual(model.episodes["s1"]?.count, 0)
        XCTAssertFalse(model.failedSeasons.contains("s1"))
    }

    func test_failure_isRecorded_andALaterLoadClearsIt() async throws {
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        XCTAssertTrue(model.failedSeasons.contains("s1"))
        XCTAssertNil(model.episodes["s1"])

        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, ["e1"]) }
        await model.load(seasonID: "s1")
        XCTAssertFalse(model.failedSeasons.contains("s1"))
        XCTAssertEqual(model.episodes["s1"]?.count, 1)
    }

    /// Tabs follow focus, so passing a season on the way to another cancels
    /// its fetch: that's not a failure, and coming back to the season must
    /// not say it couldn't load (M3 review).
    func test_cancelledLoad_isNotAFailure() async throws {
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, ["e1"]) }
        let model = makeModel()
        let load = Task { await model.load(seasonID: "s1") }
        load.cancel()
        await load.value
        XCTAssertFalse(model.failedSeasons.contains("s1"))
        await model.load(seasonID: "s1")
        XCTAssertEqual(model.episodes["s1"]?.map(\.id), ["e1"], "and it loads when shown again")
    }

    /// A refresh that fails keeps the episodes already on screen.
    func test_failedRefresh_keepsWhatWasLoaded() async throws {
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, ["e1"]) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(model.episodes["s1"]?.map(\.id), ["e1"])
        XCTAssertFalse(model.failedSeasons.contains("s1"))
    }
}
