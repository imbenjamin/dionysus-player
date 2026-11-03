import XCTest
@testable import Dionysus

@MainActor
final class TVPlaybackSessionTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlaybackSessionTests"

    /// How long a test waits to show that something did NOT happen, which
    /// can't be waited on: longer than the main-actor hops the work it rules
    /// out would take.
    private static let absenceGrace: Duration = .milliseconds(300)

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    /// Menu while the item is still loading (Review Focus 4): ending the
    /// session must cancel the start in flight, so the load it was waiting on
    /// never reaches the engine and nothing plays after the player has gone.
    func test_endWhileLoading_cancelsStart_soNothingLoadsOrPlays() async throws {
        let infoRequested = RequestFlag(), infoAnswered = RequestFlag()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDto(id: "item-1", name: "Arrival", type: .movie)
                )
            case "/Items/item-1/PlaybackInfo":
                // Still outstanding when the session ends; the test ends it
                // as soon as `infoRequested` is set, so the hold only has to
                // outlast that.
                infoRequested.set()
                Thread.sleep(forTimeInterval: 0.6)
                defer { infoAnswered.set() }
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
        try await waitUntil { infoRequested.isSet }
        session.end()
        // The answer the cancelled start was waiting for has now come back;
        // what it does with it can only be shown by waiting a moment more.
        try await waitUntil { infoAnswered.isSet }
        try await Task.sleep(for: Self.absenceGrace)

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
        try await Task.sleep(for: Self.absenceGrace)

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
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        let session = TVPlaybackSession(viewModel: viewModel)

        let first = session.end()
        XCTAssertEqual(first?.itemID, "item-1")
        XCTAssertNil(session.end(), "A second end reports nothing")
        try await waitUntil { engine.stopCallCount >= 1 }
        try await Task.sleep(for: Self.absenceGrace)
        XCTAssertEqual(engine.stopCallCount, 1, "…and the engine is stopped once")
    }

    /// Next Up's hand-off leaves the engine running for the next item, whose
    /// `load()` replaces this one's; leaving the player stops it.
    func test_end_handingOff_leavesTheEngineToTheNextItem() async throws {
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 204, body: Data()) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        func makeSession(_ engine: FakePlaybackEngine) -> TVPlaybackSession {
            TVPlaybackSession(viewModel: PlayerViewModel(
                client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
                userID: "user-1", itemID: "item-1", engine: engine,
                trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
                nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
                streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
            ))
        }
        let handedOff = FakePlaybackEngine()
        let closed = FakePlaybackEngine()

        makeSession(handedOff).end(handingOff: true)
        makeSession(closed).end()
        try await waitUntil { closed.stopCallCount == 1 }
        // Both ends ran the same synchronous path; a stop that the hand-off
        // should have skipped would have landed with the other's.
        try await Task.sleep(for: Self.absenceGrace)

        XCTAssertEqual(handedOff.stopCallCount, 0)
        XCTAssertEqual(closed.stopCallCount, 1)
    }
}

/// Set from a `MockURLProtocol` handler (a loading thread), read by the test.
private final class RequestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
