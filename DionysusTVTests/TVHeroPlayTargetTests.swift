import XCTest
@testable import Dionysus

@MainActor
final class TVHeroPlayTargetTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func client() -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession())
    }

    func test_aMovie_playsItself_withNoRequest() async {
        MockURLProtocol.requestHandler = { request in
            XCTFail("No request expected, got \(request.url?.path ?? "")")
            return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }
        let movie = MediaItem(dto: BaseItemDto(id: "m1", name: "Arrival", type: .movie), images: images)
        let target = await TVHeroPlayTarget.resolve(movie, client: client(), userID: "u")
        XCTAssertEqual(target, "m1")
    }

    /// The spike's bug: a series in the hero needs its Play to resolve an
    /// episode, since a series id itself doesn't play.
    func test_aSeries_playsItsNextUpEpisode() async {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Shows/NextUp")
            let episode = BaseItemDto(id: "e3", name: "Alone in the Night", type: .episode)
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [episode], totalRecordCount: 1))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertEqual(target, "e3")
    }

    func test_aSeriesNeverStarted_playsItsFirstEpisode() async {
        MockURLProtocol.requestHandler = { request in
            let items = request.url?.path == "/Shows/NextUp" ? [] : [BaseItemDto(id: "e1", name: "Earthfall", type: .episode)]
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertEqual(target, "e1")
    }

    func test_aSeriesWithNoEpisodes_hasNothingToPlay() async {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let series = MediaItem(dto: BaseItemDto(id: "s1", name: "Pioneer One", type: .series), images: images)
        let target = await TVHeroPlayTarget.resolve(series, client: client(), userID: "u")
        XCTAssertNil(target)
    }
}
