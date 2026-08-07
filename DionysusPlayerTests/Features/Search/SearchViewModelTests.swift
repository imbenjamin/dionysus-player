import XCTest
@testable import Dionysus

/// `SearchViewModel` is constructed with an already-resolved `client`/`userID`
/// (per the ViewModel pattern in CLAUDE.md), so it can be tested the same
/// way as the client itself: a real `JellyfinAPIClient` pointed at
/// `MockURLProtocol` instead of a network. `historyStore` is likewise real,
/// pointed at an ephemeral `UserDefaults` suite rather than `.standard`
/// (same reasoning as `ServerSessionStoreTests`) so tests can't leak state
/// into real device data or into each other.
@MainActor
final class SearchViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.SearchViewModelTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(userID: String = "user-1", accessToken: String = "tok") -> SearchViewModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: accessToken,
            session: MockURLProtocol.makeSession()
        )
        return SearchViewModel(client: client, userID: userID, historyStore: SearchHistoryStore(defaults: defaults))
    }

    func test_queryChanged_emptyQuery_clearsResultsWithoutHittingTheNetwork() {
        let viewModel = makeViewModel()
        MockURLProtocol.requestHandler = { _ in XCTFail("Should not make a request for an empty query"); throw MockURLProtocol.UnhandledRequest() }

        viewModel.query = "   "
        viewModel.queryChanged()

        XCTAssertEqual(viewModel.results, [])
        XCTAssertEqual(viewModel.loadState, .idle)
    }

    func test_queryChanged_nonEmptyQuery_debouncesThenLoadsResultsFromSearchHints() async throws {
        let viewModel = makeViewModel()
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie, productionYear: 2016)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Search/Hints")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: SearchHintResult(searchHints: [hint], totalRecordCount: 1))
        }

        viewModel.query = "arrival"
        viewModel.queryChanged()

        // The debounce sleeps 350ms before firing; poll rather than sleep a
        // fixed amount so this isn't flaky under CI load.
        try await waitUntil { viewModel.loadState == .loaded }

        XCTAssertEqual(viewModel.results.map(\.id), ["movie-1"])
        XCTAssertEqual(viewModel.results.first?.subtitle, "2016")
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

    // MARK: images

    func test_imageURL_nilBeforeLoadImagesIfNeeded() {
        let viewModel = makeViewModel()
        let result = SearchResult(hint: SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "tag"))

        XCTAssertNil(viewModel.imageURL(for: result), "Shouldn't resolve anything until loadImagesIfNeeded() has run once")
    }

    func test_loadImagesIfNeeded_resolvesImageURLsAgainstTheCurrentSession() async {
        let viewModel = makeViewModel(accessToken: "current-token")
        let result = SearchResult(hint: SearchHint(id: "movie-1", name: "Arrival", type: .movie, primaryImageTag: "tag"))

        await viewModel.loadImagesIfNeeded()

        let url = viewModel.imageURL(for: result)
        let apiKey = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.first { $0.name == "ApiKey" }
        XCTAssertEqual(apiKey?.value, "current-token", "Should resolve with whichever token this session currently has, not one baked in earlier")
    }

    // MARK: history

    func test_init_loadsExistingHistoryForThisUser() {
        let hint = SearchHint(id: "movie-1", name: "Arrival", type: .movie)
        SearchHistoryStore(defaults: defaults).record(SearchResult(hint: hint), userID: "user-1")

        let viewModel = makeViewModel(userID: "user-1")
        XCTAssertEqual(viewModel.history.map(\.id), ["movie-1"])
    }

    func test_recordSelection_addsToHistoryAndPersists() {
        let viewModel = makeViewModel()
        let result = SearchResult(hint: SearchHint(id: "movie-1", name: "Arrival", type: .movie))

        viewModel.recordSelection(result)

        XCTAssertEqual(viewModel.history, [result])
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).history(userID: "user-1"), [result], "Should persist beyond this instance")
    }

    func test_clearHistory_removesAllEntries() {
        let viewModel = makeViewModel()
        viewModel.recordSelection(SearchResult(hint: SearchHint(id: "movie-1", name: "Arrival", type: .movie)))

        viewModel.clearHistory()

        XCTAssertEqual(viewModel.history, [])
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).history(userID: "user-1"), [])
    }

    func test_removeFromHistory_removesOnlyThatEntryAndPersists() {
        let viewModel = makeViewModel()
        let keep = SearchResult(hint: SearchHint(id: "movie-1", name: "Arrival", type: .movie))
        let remove = SearchResult(hint: SearchHint(id: "movie-2", name: "Interstellar", type: .movie))
        viewModel.recordSelection(keep)
        viewModel.recordSelection(remove)

        viewModel.removeFromHistory(remove)

        XCTAssertEqual(viewModel.history, [keep])
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).history(userID: "user-1"), [keep], "Should persist beyond this instance")
    }
}
