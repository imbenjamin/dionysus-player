import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerCommandRunnerTests: XCTestCase {
    /// Unique per test: a shared suite let one test see another's saved offset.
    private let suiteName = "com.dionysusplayer.tests.TVPlayerCommandRunnerTests.\(UUID().uuidString)"

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
        try await waitUntil {
            engine.pauseCallCount == 1 && engine.playCallCount == 1 && engine.togglePlayPauseCallCount == 1
                && engine.seekedTimes == [42] && engine.selectedAudioTrackIDs == [3]
                && engine.selectedSubtitleTrackIDs == [nil] && advanced == 1 && closed == 1
        }
        XCTAssertEqual(engine.exactSeekedTimes, [])
        runner.run([.seekExact(60)])
        try await waitUntil { engine.exactSeekedTimes == [60] }

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.togglePlayPauseCallCount, 1)
        XCTAssertEqual(engine.seekedTimes, [42, 60])
        XCTAssertEqual(engine.selectedAudioTrackIDs, [3])
        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [nil])
        XCTAssertEqual(advanced, 1)
        XCTAssertEqual(closed, 1)
    }

    func test_audioOffsetCommands_reachTheController() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        engine.isAudioOffsetAvailable = true
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults),
            audioOffsetStore: AudioOffsetStore(defaults: defaults)
        )
        let runner = TVPlayerCommandRunner(viewModel: viewModel, close: {}, playNext: {})

        // The offset controller is synchronous: nothing to wait for.
        runner.run([.stepAudioOffset(2)])
        XCTAssertEqual(viewModel.audioOffset.milliseconds, 20)
        XCTAssertTrue(viewModel.audioOffset.hasTitleOffset)

        runner.run([.resetAudioOffset])
        XCTAssertFalse(viewModel.audioOffset.hasTitleOffset)

        runner.run([.setAudioOffsetScope(.allTitles)])
        XCTAssertEqual(viewModel.audioOffset.scope, .allTitles)
    }
}
