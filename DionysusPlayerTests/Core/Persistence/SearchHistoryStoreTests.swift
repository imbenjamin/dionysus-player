import XCTest
@testable import Dionysus

final class SearchHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.SearchHistoryStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeResult(id: String, name: String = "Arrival") -> SearchResult {
        let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: nil)
        return SearchResult(hint: SearchHint(id: id, name: name, type: .movie), images: images)
    }

    func test_freshStore_hasNoHistory() {
        let store = SearchHistoryStore(defaults: defaults)
        XCTAssertEqual(store.history(userID: "user-1"), [])
    }

    func test_record_persistsAcrossNewInstances() {
        let result = makeResult(id: "movie-1")
        SearchHistoryStore(defaults: defaults).record(result, userID: "user-1")

        let reloaded = SearchHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.history(userID: "user-1"), [result])
    }

    func test_record_mostRecentFirst() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-2"), userID: "user-1")

        XCTAssertEqual(store.history(userID: "user-1").map(\.id), ["movie-2", "movie-1"])
    }

    func test_record_reselectingAnExistingEntry_movesItToFrontWithoutDuplicating() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-2"), userID: "user-1")
        store.record(makeResult(id: "movie-1"), userID: "user-1")

        XCTAssertEqual(store.history(userID: "user-1").map(\.id), ["movie-1", "movie-2"])
    }

    func test_record_trimsToMaxEntries() {
        let store = SearchHistoryStore(defaults: defaults)
        for index in 0..<25 {
            store.record(makeResult(id: "movie-\(index)"), userID: "user-1")
        }

        let history = store.history(userID: "user-1")
        XCTAssertEqual(history.count, 20)
        // Most recent (highest index) first, oldest trimmed off the end.
        XCTAssertEqual(history.first?.id, "movie-24")
        XCTAssertEqual(history.last?.id, "movie-5")
    }

    func test_history_isScopedPerUser() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-2"), userID: "user-2")

        XCTAssertEqual(store.history(userID: "user-1").map(\.id), ["movie-1"])
        XCTAssertEqual(store.history(userID: "user-2").map(\.id), ["movie-2"])
    }

    func test_remove_removesOnlyThatEntry() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-2"), userID: "user-1")

        store.remove(id: "movie-1", userID: "user-1")

        XCTAssertEqual(store.history(userID: "user-1").map(\.id), ["movie-2"])
    }

    func test_remove_scopedToThatUserOnly() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-1"), userID: "user-2")

        store.remove(id: "movie-1", userID: "user-1")

        XCTAssertEqual(store.history(userID: "user-1"), [])
        XCTAssertEqual(store.history(userID: "user-2").map(\.id), ["movie-1"])
    }

    func test_clear_removesHistoryForThatUserOnly() {
        let store = SearchHistoryStore(defaults: defaults)
        store.record(makeResult(id: "movie-1"), userID: "user-1")
        store.record(makeResult(id: "movie-2"), userID: "user-2")

        store.clear(userID: "user-1")

        XCTAssertEqual(store.history(userID: "user-1"), [])
        XCTAssertEqual(store.history(userID: "user-2").map(\.id), ["movie-2"])
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).history(userID: "user-1"), [], "Should also be gone from UserDefaults, not just this instance")
    }
}
