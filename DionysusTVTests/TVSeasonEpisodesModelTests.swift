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

    nonisolated private static func episodesResponse(_ request: URLRequest, played: [String: Bool]) throws -> (HTTPURLResponse, Data) {
        let items = played.keys.sorted().map {
            BaseItemDto(id: $0, name: $0, type: .episode, userData: UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 0, played: played[$0]))
        }
        return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
    }

    /// Watched and Favorite on a show's page act on the chosen episode, which
    /// only this model holds (Benjamin, 2026-10-25).
    func test_applyStatus_marksThatEpisodeAlone() async throws {
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, played: ["e1": false, "e2": false]) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        model.applyStatus(itemID: "e2", watched: true)
        XCTAssertEqual(model.episodes["s1"]?.map(\.isPlayed), [false, true])
        model.applyStatus(itemID: "e2", favorite: true)
        XCTAssertEqual(model.episodes["s1"]?.map(\.isFavorite), [false, true])
        XCTAssertEqual(model.episodes["s1"]?.last?.isPlayed, true, "A favorite write keeps the watched one")
    }

    /// Jellyfin commits userData late: a refetch still reporting the old value
    /// mustn't undo the write on screen, and one that agrees ends the override.
    func test_applyStatus_survivesAStaleRefetch_untilTheServerAgrees() async throws {
        nonisolated(unsafe) var serverPlayed = false
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, played: ["e1": serverPlayed]) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        model.applyStatus(itemID: "e1", watched: true)
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(model.episodes["s1"]?.first?.isPlayed, true, "A stale refetch keeps the write")

        serverPlayed = true
        await model.load(seasonID: "s1", force: true)
        serverPlayed = false
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(model.episodes["s1"]?.first?.isPlayed, false, "Once confirmed, the server speaks for itself again")
    }

    /// After playback the server is the source again.
    func test_forgetStatusOverrides_letsTheServerSpeak() async throws {
        MockURLProtocol.requestHandler = { request in try Self.episodesResponse(request, played: ["e1": true]) }
        let model = makeModel()
        await model.load(seasonID: "s1")
        model.applyStatus(itemID: "e1", favorite: true, watched: false)
        model.forgetStatusOverrides()
        await model.load(seasonID: "s1", force: true)
        XCTAssertEqual(model.episodes["s1"]?.first?.isPlayed, true)
        XCTAssertEqual(model.episodes["s1"]?.first?.isFavorite, false)
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

    /// After a deletion every other season's list may be stale, so only the
    /// seasons kept stay cached; the rest are fetched again when next on show.
    func test_retain_dropsEverySeasonButThoseKept() async throws {
        nonisolated(unsafe) var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try Self.episodesResponse(request, ["e"])
        }
        let model = makeModel()
        await model.load(seasonID: "s1")
        await model.load(seasonID: "s2")
        await model.load(seasonID: "s3")
        model.retain(["s2"])
        XCTAssertEqual(Set(model.episodes.keys), ["s2"])
        await model.load(seasonID: "s1")
        XCTAssertEqual(requests, 4, "A dropped season is fetched again")
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
