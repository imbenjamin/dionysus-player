import XCTest
@testable import Dionysus

/// Night Mode in the player: what a load carries, what a change mid-session
/// does to the engine, and the Spatial Audio order when Night Audio ends.
@MainActor
final class PlayerViewModelNightModeTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private let suiteName = "com.dionysusplayer.tests.PlayerViewModelNightModeTests"
    private var defaults: UserDefaults!
    private var calendar: Calendar!
    private var clock: Date!
    private var nightMode: NightModeController!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        ConnectivityMonitor.shared.reset()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        clock = date(hour: 12)
        nightMode = NightModeController(
            store: NightModeStore(storage: InMemoryStorage()),
            now: { [unowned self] in clock }, calendar: calendar, schedulesWakes: false
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
    }

    private func makeViewModel(
        engine: FakePlaybackEngine, spatialAudio: SpatialAudioSettings = SpatialAudioSettings()
    ) -> PlayerViewModel {
        let spatialStore = SpatialAudioStore(storage: defaults)
        spatialStore.settings = spatialAudio
        return PlayerViewModel(
            client: JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults),
            audioOffsetStore: AudioOffsetStore(defaults: defaults),
            spatialAudioStore: spatialStore,
            versionPreferenceStore: MediaVersionPreferenceStore(defaults: defaults),
            nightMode: nightMode
        )
    }

    private func stubStart(mediaSources: [MediaSourceInfo] = [MediaSourceInfo(id: "src-1", container: "mp4")]) {
        let itemDto = BaseItemDto(id: "item-1", name: "Dune", type: .movie)
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/item-1/PlaybackInfo":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaybackInfoResponse(mediaSources: mediaSources, playSessionId: "sess-1")
                )
            case "/MediaSegments/item-1":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0)
                )
            default:
                if path.hasPrefix("/Sessions/Playing") {
                    return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
                }
                XCTFail("unexpected request to \(path)")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }
    }

    /// A TrueHD Atmos track, engine id 1, with Atmos rendered in 7.1.4.
    private func stubAtmos(engine: FakePlaybackEngine) -> SpatialAudioSettings {
        engine.audioTracks = [PlaybackTrack(id: 1, kind: .audio, title: "TrueHD Atmos", metadata: nil, isSelected: true)]
        stubStart(mediaSources: [MediaSourceInfo(id: "src-1", container: "mkv", mediaStreams: [
            MediaStream(index: 0, type: "Video"),
            MediaStream(index: 1, type: "Audio", codec: "truehd", language: "eng", isDefault: true, audioSpatialFormat: "DolbyAtmos"),
        ])])
        var settings = SpatialAudioSettings()
        settings.atmosEnabled = true
        settings.atmosLayout = .l714
        return settings
    }

    /// Night Mode on: Night Audio, Volume Limit 60%, Brightness 40%.
    private func turnNightModeOn() {
        nightMode.setVolumePercent(60)
        nightMode.setBrightnessPercent(40)
        nightMode.setOn(true)
    }

    // MARK: At load

    func test_start_loadsWithNightAudioAndVolume_whenOn() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)

        await viewModel.start()

        XCTAssertEqual(engine.loadedNightAudio, true)
        XCTAssertEqual(engine.outputVolume, 0.6, accuracy: 0.0001)
        XCTAssertEqual(viewModel.videoDimOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(engine.nightAudioCalls, [], "Passed at load, not rebuilt after it")
    }

    func test_start_loadsPlain_whenOff() async {
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)

        await viewModel.start()

        XCTAssertEqual(engine.loadedNightAudio, false)
        XCTAssertEqual(engine.outputVolume, 1)
        XCTAssertEqual(viewModel.videoDimOpacity, 0)
        XCTAssertNil(viewModel.stats.nightMode)
    }

    /// Night Audio overrides the object render, so loading with Spatial Audio
    /// would build a bed only to have it replaced.
    func test_loadsWithSpatialOff_whileNightAudio() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        let viewModel = makeViewModel(engine: engine, spatialAudio: stubAtmos(engine: engine))

        await viewModel.start()

        XCTAssertEqual(engine.loadedSpatialAudio, [.off])
        XCTAssertEqual(engine.spatialAudioReloads, [], "No correction while Night Audio is in force")
    }

    /// The Apple TV's Next Up hands the engine to the next item's view
    /// model, whose load applies Night Mode as it stands then, whatever the
    /// engine was left at.
    func test_nextItem_keepsNightSettings() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        stubStart()
        let first = makeViewModel(engine: engine)
        await first.start()
        await first.stop(handingOff: true)
        nightMode.setVolumePercent(30)
        XCTAssertEqual(engine.outputVolume, 0.6, accuracy: 0.0001, "The stopped player no longer follows")

        let next = makeViewModel(engine: engine)
        engine.outputVolume = 1
        await next.start()

        XCTAssertEqual(engine.loadedOutputVolumes.count, 2)
        XCTAssertEqual(engine.loadedOutputVolumes.last ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(engine.loadedNightAudio, true)
        XCTAssertEqual(next.videoDimOpacity, 0.6, accuracy: 0.0001)
    }

    // MARK: Mid-session

    func test_turningOn_midSession_appliesAll() async {
        nightMode.setVolumePercent(60)
        nightMode.setBrightnessPercent(40)
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)
        await viewModel.start()

        nightMode.setOn(true)

        XCTAssertEqual(engine.nightAudioCalls, [true])
        XCTAssertEqual(engine.outputVolume, 0.6, accuracy: 0.0001)
        XCTAssertEqual(viewModel.videoDimOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(viewModel.stats.nightMode, "Night Audio · Volume 60% · Brightness 40%")
    }

    /// A level costs nothing to change: only Night Audio rebuilds the session.
    func test_levelChange_appliesVolumeAndDim_withoutRebuild() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)
        await viewModel.start()

        nightMode.setVolumePercent(30)
        nightMode.setBrightnessPercent(70)

        XCTAssertEqual(engine.outputVolume, 0.3, accuracy: 0.0001)
        XCTAssertEqual(viewModel.videoDimOpacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(engine.nightAudioCalls, [])
    }

    /// Turning shaping off and the Spatial Audio rebuild are both reloads at
    /// the playhead; the shaping goes first so the render's rebuild is the
    /// last word, and reads the shaping already off.
    func test_nightAudioOff_beforeSpatialCorrection() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        let viewModel = makeViewModel(engine: engine, spatialAudio: stubAtmos(engine: engine))
        await viewModel.start()

        nightMode.setNightAudio(false)
        await viewModel.awaitSpatialAudioCorrection()

        XCTAssertEqual(engine.audioEvents.suffix(2), [.setNightAudio(false), .setSpatialAudio(.layout(.l714))])
    }

    /// An audio switch while Night Audio is in force must not rebuild the
    /// render it overrides; the one correction follows when Night Audio ends.
    func test_audioSwitch_whileNightAudio_defersSpatialCorrection() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        let viewModel = makeViewModel(engine: engine, spatialAudio: stubAtmos(engine: engine))
        await viewModel.start()

        viewModel.selectAudioTrack(id: 1)
        await viewModel.awaitSpatialAudioCorrection()
        XCTAssertEqual(engine.spatialAudioReloads, [], "No rebuild while Night Audio is in force")

        nightMode.setNightAudio(false)
        await viewModel.awaitSpatialAudioCorrection()
        XCTAssertEqual(engine.spatialAudioReloads, [.layout(.l714)])
    }

    /// AetherEngine folds repeats into the rebuild in flight, so each toggle
    /// goes straight through, with nothing waited on.
    func test_rapidToggles_callEngineEachTime_withoutAwaiting() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)
        await viewModel.start()

        nightMode.setNightAudio(false)
        nightMode.setNightAudio(true)
        nightMode.setNightAudio(false)

        XCTAssertEqual(engine.nightAudioCalls, [false, true, false])
    }

    /// A server transcode: AVPlayer owns the audio, so the engine reports the
    /// compressor can't apply, and the stats row says so.
    func test_remoteHLS_reportsUnavailable() async {
        turnNightModeOn()
        let engine = FakePlaybackEngine()
        var source = MediaSourceInfo(id: "src-1", container: "mkv")
        source.transcodingUrl = "/videos/item-1/master.m3u8?x=1"
        stubStart(mediaSources: [source])
        let viewModel = makeViewModel(engine: engine)

        await viewModel.start()

        XCTAssertEqual(engine.loadedIsRemoteHLS, [true])
        XCTAssertEqual(viewModel.nightAudioState, .unavailable)
        XCTAssertEqual(viewModel.stats.nightMode, "Night Audio unavailable · Volume 60% · Brightness 40%")
    }

    /// The schedule turning Night Mode on while a title plays reaches it.
    func test_boundaryDuringPlayback_applies() async {
        clock = date(hour: 21, minute: 30)
        nightMode.setBrightnessPercent(40)
        nightMode.setSchedule(NightModeSchedule(
            isEnabled: true, turnOn: TimeOfDay(hour: 22, minute: 0), turnOff: TimeOfDay(hour: 7, minute: 0)
        ))
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)
        await viewModel.start()
        XCTAssertEqual(viewModel.videoDimOpacity, 0)

        clock = date(hour: 22, minute: 1)
        nightMode.evaluate()

        XCTAssertEqual(viewModel.videoDimOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(engine.nightAudioCalls, [true])
    }

    /// A closed player leaves the engine alone: the next one applies its own.
    func test_stop_stopsFollowingNightMode() async {
        let engine = FakePlaybackEngine()
        stubStart()
        let viewModel = makeViewModel(engine: engine)
        await viewModel.start()
        await viewModel.stop()

        turnNightModeOn()

        XCTAssertEqual(engine.nightAudioCalls, [])
        XCTAssertEqual(engine.outputVolume, 1)
    }
}
