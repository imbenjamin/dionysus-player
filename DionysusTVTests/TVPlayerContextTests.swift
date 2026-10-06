import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerContextTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlayerContextTests"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_playbackStates_mapToWhatThePlayerAcceptsInputIn() {
        XCTAssertEqual(TVPlayerContext.playback(.idle), .loading)
        XCTAssertEqual(TVPlayerContext.playback(.loading), .loading)
        XCTAssertEqual(TVPlayerContext.playback(.playing), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.buffering), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.seeking), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.reconnecting), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.paused), .paused)
        XCTAssertEqual(TVPlayerContext.playback(.ended), .ended)
    }

    func test_tracksAndSettings_comeFromTheViewModelAndDefaults() {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [
            PlaybackTrack(id: 4, kind: .audio, title: "English", metadata: nil, isSelected: false),
            PlaybackTrack(id: 7, kind: .audio, title: "Commentary", metadata: nil, isSelected: true)
        ]
        engine.subtitleTracks = [PlaybackTrack(id: 2, kind: .subtitle, title: "English", metadata: nil, isSelected: false)]
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        defaults.set(true, forKey: showPlaybackStatsButtonEnabledStorageKey)
        defaults.set(false, forKey: chaptersInScrubberEnabledStorageKey)

        let context = TVPlayerContext(viewModel: viewModel, defaults: defaults)

        XCTAssertEqual(context.audioTrackIDs, [4, 7])
        XCTAssertEqual(context.selectedAudioIndex, 1)
        XCTAssertEqual(context.subtitleTrackIDs, [2])
        XCTAssertNil(context.selectedSubtitleIndex)
        XCTAssertTrue(context.statsButtonEnabled)
        XCTAssertFalse(context.chaptersInScrubber)
    }
}
