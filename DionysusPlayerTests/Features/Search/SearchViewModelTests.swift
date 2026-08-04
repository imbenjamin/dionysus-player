import XCTest
@testable import Dionysus

/// `SearchViewModel` is constructed with an already-resolved `client`/`userID`
/// (per the ViewModel pattern in CLAUDE.md), so it can be tested the same
/// way as the client itself: a real `JellyfinAPIClient` pointed at
/// `MockURLProtocol` instead of a network.
@MainActor
final class SearchViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel() -> SearchViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "tok",
            session: MockURLProtocol.makeSession()
        )
        return SearchViewModel(client: client, userID: "user-1")
    }

    func test_queryChanged_emptyQuery_clearsResultsWithoutHittingTheNetwork() {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { _ in XCTFail("Should not make a request for an empty query"); throw MockURLProtocol.UnhandledRequest() }

        viewModel.query = "   "
        viewModel.queryChanged()

        XCTAssertEqual(viewModel.results, [])
        XCTAssertEqual(viewModel.loadState, .idle)
    }

    func test_queryChanged_nonEmptyQuery_debouncesThenLoadsResults() async throws {
        let viewModel = makeViewModel()
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie)
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }

        viewModel.query = "arrival"
        viewModel.queryChanged()

        // The debounce sleeps 350ms before firing; poll rather than sleep a
        // fixed amount so this isn't flaky under CI load.
        try await waitUntil { viewModel.loadState == .loaded }

        XCTAssertEqual(viewModel.results.map(\.id), ["movie-1"])
    }

    func test_queryChanged_serverError_setsFailedState() async throws {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        viewModel.query = "arrival"
        viewModel.queryChanged()

        try await waitUntil {
            if case .failed = viewModel.loadState { return true }
            return false
        }
    }

}
