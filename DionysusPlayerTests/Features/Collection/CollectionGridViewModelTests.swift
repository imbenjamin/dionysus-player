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
        let query = CollectionQuery(title: "Movies", parentID: "lib-movies", includeItemTypes: ["Movie"])
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
    }

    func test_load_defaultsToTitleAscendingSort() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Collections", includeItemTypes: ["BoxSet"]))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.sortField, .title)
        XCTAssertEqual(viewModel.sortOrder, .ascending)
        XCTAssertEqual(captured["SortBy"], "SortName")
        XCTAssertEqual(captured["SortOrder"], "Ascending")
        XCTAssertNil(captured["ParentId"])
    }

    // MARK: setSortField

    func test_setSortField_changesFieldAndReloads() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.dateAdded)

        XCTAssertEqual(viewModel.sortField, .dateAdded)
        XCTAssertEqual(captured["SortBy"], "DateCreated")
    }

    func test_setSortField_releaseDate() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.releaseDate)

        XCTAssertEqual(captured["SortBy"], "PremiereDate")
    }

    func test_setSortField_reselectingCurrentField_doesNotRefetch() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()
        XCTAssertEqual(requestCount, 1)

        await viewModel.setSortField(.title)
        XCTAssertEqual(requestCount, 1, "Already the current field (and the default) — shouldn't refetch")
    }

    // MARK: setSortOrder

    /// The actual point of this round of work: direction is independent of
    /// field, so a non-Title field can be flipped to ascending too (not
    /// locked to descending the way an earlier version of this had it).
    func test_setSortOrder_flipsDirectionIndependentlyOfField() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortField(.dateAdded)
        await viewModel.setSortOrder(.ascending)

        XCTAssertEqual(viewModel.sortField, .dateAdded)
        XCTAssertEqual(viewModel.sortOrder, .ascending)
        XCTAssertEqual(captured["SortBy"], "DateCreated")
        XCTAssertEqual(captured["SortOrder"], "Ascending")
    }

    func test_setSortOrder_descendingForTitle() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var captured: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            captured = request.queryDictionary
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.setSortOrder(.descending)

        XCTAssertEqual(viewModel.sortField, .title, "Setting order alone shouldn't change the field")
        XCTAssertEqual(captured["SortBy"], "SortName")
        XCTAssertEqual(captured["SortOrder"], "Descending")
    }

    func test_setSortOrder_reselectingCurrentOrder_doesNotRefetch() async {
        let viewModel = makeViewModel(query: CollectionQuery(title: "Movies"))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }

        await viewModel.load()
        XCTAssertEqual(requestCount, 1)

        await viewModel.setSortOrder(.ascending)
        XCTAssertEqual(requestCount, 1, "Already the current order (and the default) — shouldn't refetch")
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
