import XCTest
@testable import Dionysus

@MainActor
final class CollectionGridViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(query: CollectionQuery) -> CollectionGridViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        return CollectionGridViewModel(client: client, userID: "user-1", query: query)
    }

    func test_load_passesQueryParametersThroughAndMapsItems() async {
        let query = CollectionQuery(title: "Movies", parentID: "lib-movies", includeItemTypes: ["Movie"], sortBy: "DateCreated", sortOrder: "Descending")
        let viewModel = makeViewModel(query: query)
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.items.map(\.id), ["movie-1"])
        XCTAssertEqual(captured["ParentId"], "lib-movies")
        XCTAssertEqual(captured["IncludeItemTypes"], "Movie")
        XCTAssertEqual(captured["SortBy"], "DateCreated")
        XCTAssertEqual(captured["SortOrder"], "Descending")
    }

    func test_load_defaultsToSortNameAscendingWhenQueryDoesNotOverride() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Collections", includeItemTypes: ["BoxSet"]))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()

        XCTAssertEqual(captured["SortBy"], "SortName")
        XCTAssertEqual(captured["SortOrder"], "Ascending")
        XCTAssertNil(captured["ParentId"])
    }

    func test_load_serverError_setsFailedState() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        await viewModel.load()

        guard case .failed = viewModel.loadState else { return XCTFail("Expected .failed, got \(viewModel.loadState)") }
    }

    func test_loadIfNeeded_doesNotRefetchOnceItemsArePopulated() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()
        XCTAssertEqual(requestCount, 1, "Should not re-fetch once items are already populated")
    }
}
