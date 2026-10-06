import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerCommandRunnerTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlayerCommandRunnerTests"

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_commands_reachTheEngineThroughTheViewModel() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        var closed = 0
        var advanced = 0
        let runner = TVPlayerCommandRunner(viewModel: viewModel, close: { closed += 1 }, playNext: { advanced += 1 })

        runner.run([.pause, .play, .togglePlayPause, .seek(42), .selectAudio(id: 3), .selectSubtitle(id: nil), .playNext, .close])
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.togglePlayPauseCallCount, 1)
        XCTAssertEqual(engine.seekedTimes, [42])
        XCTAssertEqual(engine.selectedAudioTrackIDs, [3])
        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [nil])
        XCTAssertEqual(advanced, 1)
        XCTAssertEqual(closed, 1)
    }
}
