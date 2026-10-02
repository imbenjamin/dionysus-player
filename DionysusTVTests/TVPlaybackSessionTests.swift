import XCTest
@testable import Dionysus

@MainActor
final class TVPlaybackSessionTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlaybackSessionTests"

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    /// Menu while the item is still loading (Review Focus 4): ending the
    /// session must cancel the start in flight, so the load it was waiting on
    /// never reaches the engine and nothing plays after the player has gone.
    func test_endWhileLoading_cancelsStart_soNothingLoadsOrPlays() async throws {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDto(id: "item-1", name: "Arrival", type: .movie)
                )
            case "/Items/item-1/PlaybackInfo":
                // Still outstanding when the session ends.
                Thread.sleep(forTimeInterval: 0.6)
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")], playSessionId: "sess-1")
                )
            default:
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            }
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        let session = TVPlaybackSession(viewModel: viewModel)

        session.begin()
        try await Task.sleep(for: .milliseconds(200))
        session.end()
        try await Task.sleep(for: .seconds(1))

        XCTAssertTrue(engine.loadedURLs.isEmpty, "The cancelled start must not load")
        XCTAssertEqual(engine.playCallCount, 0, "…or play")
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    /// Menu pressed while the player is still being presented ends the session
    /// before the host's `viewDidAppear` begins it; that late begin must not
    /// start playback behind a player that is already closing.
    func test_beginAfterEnd_startsNothing() async throws {
        MockURLProtocol.requestHandler = { request in
            // `stop()` still reports to `/Sessions/Playing/Stopped`.
            if request.url?.path == "/Users/user-1/Items/item-1" { XCTFail("start() ran after end()") }
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        let session = TVPlaybackSession(viewModel: viewModel)

        session.end()
        session.begin()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(viewModel.item, "No item fetch after the session ended")
        XCTAssertTrue(engine.loadedURLs.isEmpty)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    /// The presenter learns where playback stopped from the session, once:
    /// Menu can call `end()` twice (during presentation, then again from
    /// `viewDidAppear`), and the page beneath must not be told twice.
    func test_end_reportsTheOutcomeOnce() async throws {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: FakePlaybackEngine(),
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        let session = TVPlaybackSession(viewModel: viewModel)

        let first = session.end()
        XCTAssertEqual(first?.itemID, "item-1")
        XCTAssertNil(session.end(), "A second end reports nothing")
        try await Task.sleep(for: .milliseconds(200))
    }
}
