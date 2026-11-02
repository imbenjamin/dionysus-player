import XCTest
@testable import Dionysus

/// The sidebar's own fetch of the user's libraries. It outlives Home, so it
/// loads separately, and a `TabView` rebuild cancelling its `.task` must not
/// leave it without libraries (Home's M1 final-review finding).
@MainActor
final class TVSidebarModelTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private static let viewsWithMusic: [BaseItemDto] = [
        BaseItemDto(id: "lib-movies", name: "Movies", type: .collectionFolder, collectionType: JellyfinCollectionType.movies),
        BaseItemDto(id: "lib-tvshows", name: "TV Shows", type: .collectionFolder, collectionType: JellyfinCollectionType.tvShows),
        BaseItemDto(id: "lib-boxsets", name: "Collections", type: .collectionFolder, collectionType: JellyfinCollectionType.boxSets),
        BaseItemDto(id: "lib-playlists", name: "Playlists", type: .collectionFolder, collectionType: JellyfinCollectionType.playlists),
        BaseItemDto(id: "lib-music", name: "Music", type: .collectionFolder, collectionType: JellyfinCollectionType.music)
    ]

    private func makeModel() -> TVSidebarModel {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!,
            accessToken: "tok",
            session: MockURLProtocol.makeSession()
        )
        return TVSidebarModel(client: client, userID: "u1")
    }

    /// Answers `/Users/u1/Views`; `delay` holds each answer so a load can be
    /// caught mid-flight.
    private func installViewsHandler(status: Int = 200, views: [BaseItemDto] = viewsWithMusic, delay: TimeInterval = 0) {
        MockURLProtocol.requestHandler = { request in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard request.url?.path == "/Users/u1/Views" else {
                throw URLError(.unsupportedURL)
            }
            return try MockURLProtocol.encodedJSONResponse(
                for: request, status: status,
                value: BaseItemDtoQueryResult(items: views, totalRecordCount: views.count)
            )
        }
    }

    func test_load_listsVideoLibraries_withoutMusic() async {
        installViewsHandler()
        let model = makeModel()
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.libraries.map(\.id), ["lib-movies", "lib-tvshows", "lib-boxsets", "lib-playlists"])
    }

    /// A `TabView` rebuild cancels the sidebar's `.task` mid-request. The load
    /// runs in a task of its own, so it finishes anyway, as Home's does.
    func test_loadIfNeeded_callerCancelled_loadStillFinishes() async throws {
        installViewsHandler(delay: 0.1)
        let model = makeModel()
        let task = Task { await model.loadIfNeeded() }
        try await waitUntil { model.loadState == .loading }
        task.cancel()
        await task.value
        try await waitUntil(timeout: 10) { model.loadState == .loaded }
        XCTAssertEqual(model.libraries.count, 4)
    }

    /// The rebuilt sidebar's new `.task` arrives while the first load is still
    /// in flight, and joins it rather than returning to an unsettled state.
    func test_loadIfNeeded_secondCallerJoinsTheInFlightLoad() async throws {
        installViewsHandler(delay: 0.1)
        let model = makeModel()
        let first = Task { await model.loadIfNeeded() }
        try await waitUntil { model.loadState == .loading }
        first.cancel()
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .loaded)
    }

    /// A failed load leaves Home, Search and Profile usable. The sidebar
    /// just has no library entries, and the next `loadIfNeeded()` tries again.
    func test_failedLoad_isRetriedByTheNextLoadIfNeeded() async {
        installViewsHandler(status: 500)
        let model = makeModel()
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertTrue(model.libraries.isEmpty)
        installViewsHandler()
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .loaded)
    }
}
