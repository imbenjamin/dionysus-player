import XCTest
@testable import Dionysus

/// `PlayerViewModel` was previously untested — it's the one place that ties
/// the Jellyfin networking layer to a `PlaybackEngine`, so it's worth
/// pinning: resume-position seeking, the start-from-beginning override,
/// playback-progress reporting, and that transport controls delegate
/// straight through to the engine. `FakePlaybackEngine` (Support/) stands
/// in for AetherEngine.
@MainActor
final class PlayerViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(
        itemID: String = "item-1",
        startFromBeginning: Bool = false,
        mediaSourceID: String? = nil,
        engine: FakePlaybackEngine = FakePlaybackEngine()
    ) -> (PlayerViewModel, FakePlaybackEngine) {
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: "user-1", itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID
        )
        return (viewModel, engine)
    }

    /// Standard item/playbackInfo/session-start stubbing shared by most
    /// `start()` tests; `itemDto` varies per test (e.g. to add a resume
    /// position), everything else is boilerplate.
    private func stubStart(itemID: String = "item-1", itemDto: BaseItemDto, mediaSources: [MediaSourceInfo]? = nil) {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/\(itemID)/PlaybackInfo":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse(mediaSources: mediaSources, playSessionId: "sess-1"))
            case "/Sessions/Playing":
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }
    }

    // MARK: start()

    func test_start_freshPlayback_loadsStreamURLAndPlaysWithoutSeeking() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.item?.id, "item-1")
        XCTAssertEqual(engine.loadedURLs.count, 1)
        let loadedURL = engine.loadedURLs[0].absoluteString
        XCTAssertTrue(loadedURL.contains("MediaSourceId=src-1"))
        XCTAssertTrue(loadedURL.contains("Container=mp4"))
        XCTAssertTrue(engine.seekedTimes.isEmpty, "Nothing to resume, so it shouldn't seek")
        XCTAssertEqual(engine.playCallCount, 1)
    }

    /// A requested version (the version-choice prompt's answer, or a
    /// remembered preference — see `PlaybackRequest.mediaSourceID`) should
    /// both scope the `/PlaybackInfo` request and drive which of the
    /// returned sources actually gets played, not just fall through to
    /// `.first` as before this existed.
    func test_start_withRequestedMediaSourceID_selectsThatSourceAndReportsItActive() async {
        let (viewModel, engine) = makeViewModel(mediaSourceID: "src-1080p")
        var requestedMediaSourceId: String?
        var reportedStartMediaSourceId: String?
        struct DecodedPlaybackInfoBody: Decodable { let MediaSourceId: String? }
        struct DecodedProgressBody: Decodable { let MediaSourceId: String? }
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "item-1", name: "1917", type: .movie))
            case "/Items/item-1/PlaybackInfo":
                requestedMediaSourceId = try JSONDecoder().decode(DecodedPlaybackInfoBody.self, from: request.capturedHTTPBody ?? Data()).MediaSourceId
                return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse(
                    mediaSources: [MediaSourceInfo(id: "src-4k", container: "mkv"), MediaSourceInfo(id: "src-1080p", container: "mp4")]
                ))
            case "/Sessions/Playing":
                reportedStartMediaSourceId = try JSONDecoder().decode(DecodedProgressBody.self, from: request.capturedHTTPBody ?? Data()).MediaSourceId
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        await viewModel.start()

        XCTAssertEqual(requestedMediaSourceId, "src-1080p", "PlaybackInfo should be scoped to the requested version")
        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("MediaSourceId=src-1080p"))
        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("Container=mp4"), "Should use the matched source's own container, not the first one's")
        XCTAssertEqual(viewModel.activeMediaSourceID, "src-1080p")
        XCTAssertEqual(reportedStartMediaSourceId, "src-1080p", "The active session should reflect which version is actually playing")
    }

    /// A stale/unrecognized requested id (e.g. a remembered preference for a
    /// version since removed from the server) shouldn't fail playback
    /// outright — falls back to the server's own default source, same as
    /// no request at all.
    func test_start_withUnrecognizedRequestedMediaSourceID_fallsBackToFirstSource() async {
        let (viewModel, engine) = makeViewModel(mediaSourceID: "src-deleted")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "1917", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-4k", container: "mkv"), MediaSourceInfo(id: "src-1080p", container: "mp4")]
        )

        await viewModel.start()

        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("MediaSourceId=src-4k"))
        XCTAssertEqual(viewModel.activeMediaSourceID, "src-4k")
    }

    func test_start_resumesFromSavedPositionWhenNotStartingFromBeginning() async {
        let (viewModel, engine) = makeViewModel(startFromBeginning: false)
        let dto = BaseItemDto(
            id: "item-1", name: "Arrival", type: .movie,
            runTimeTicks: 100 * 10_000_000, userData: UserItemDataDto(playbackPositionTicks: 30 * 10_000_000)
        )
        stubStart(itemDto: dto)

        await viewModel.start()

        XCTAssertEqual(engine.seekedTimes, [30])
        XCTAssertEqual(engine.playCallCount, 1)
    }

    func test_start_startFromBeginning_skipsSeekEvenWithAResumePosition() async {
        let (viewModel, engine) = makeViewModel(startFromBeginning: true)
        let dto = BaseItemDto(
            id: "item-1", name: "Arrival", type: .movie,
            runTimeTicks: 100 * 10_000_000, userData: UserItemDataDto(playbackPositionTicks: 30 * 10_000_000)
        )
        stubStart(itemDto: dto)

        await viewModel.start()

        XCTAssertTrue(engine.seekedTimes.isEmpty)
        XCTAssertEqual(engine.playCallCount, 1)
    }

    /// `sourceVideoStream` is what `PlaybackStatsOverlay` reads
    /// `videoRangeType` off of for the Dolby Vision "Enhancement Layer" row
    /// — it should come from the video stream of whichever source `start()`
    /// actually resolved to, not just the first stream on it.
    func test_start_setsSourceVideoStreamFromResolvedMediaSourcesVideoStream() async {
        let (viewModel, _) = makeViewModel()
        let videoStream = MediaStream(index: 0, type: "Video", videoRangeType: "DOVIWithHDR10")
        let audioStream = MediaStream(index: 1, type: "Audio")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4", mediaStreams: [audioStream, videoStream])]
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.sourceVideoStream?.videoRangeType, "DOVIWithHDR10")
    }

    func test_start_engineLoadThrows_setsErrorMessageAndNeverCallsPlay() async {
        let engine = FakePlaybackEngine()
        engine.loadError = URLError(.badURL)
        let (viewModel, _) = makeViewModel(engine: engine)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    // MARK: transport controls delegate to the engine

    func test_togglePlayPause_delegatesToEngine() {
        let (viewModel, engine) = makeViewModel()
        viewModel.togglePlayPause()
        XCTAssertEqual(engine.togglePlayPauseCallCount, 1)
    }

    func test_seek_delegatesToEngineAsynchronously() async throws {
        let (viewModel, engine) = makeViewModel()
        viewModel.seek(to: 42)
        try await waitUntil { engine.seekedTimes.contains(42) }
    }

    func test_selectAudioAndSubtitleTracks_delegateToEngine() {
        let (viewModel, engine) = makeViewModel()
        viewModel.selectAudioTrack(id: 2)
        viewModel.selectSubtitleTrack(id: nil)
        XCTAssertEqual(engine.selectedAudioTrackIDs, [2])
        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [nil])
    }

    func test_setZoomMode_delegatesToEngine() {
        let (viewModel, engine) = makeViewModel()
        viewModel.setZoomMode(.fill)
        XCTAssertEqual(engine.zoomMode, .fill)
    }

    // MARK: stop()

    func test_stop_reportsCurrentPositionAsTicksAndStopsEngine() async throws {
        let (viewModel, engine) = makeViewModel()
        // Simulate the engine reporting playback progress, same as it would
        // mid-session via the `onTimeUpdate` callback wired up in `init`.
        engine.onTimeUpdate?(75, 5400)
        XCTAssertEqual(viewModel.currentTime, 75)

        var reportedTicks: Int64?
        struct StoppedBody: Decodable { let PositionTicks: Int64 }
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Sessions/Playing/Stopped" {
                reportedTicks = try JSONDecoder().decode(StoppedBody.self, from: request.capturedHTTPBody ?? Data()).PositionTicks
            }
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await viewModel.stop()

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(reportedTicks, 75 * 10_000_000)
    }

    // MARK: engine → ViewModel callbacks

    func test_engineStateAndTimeCallbacks_updateViewModelState() {
        let (viewModel, engine) = makeViewModel()

        engine.onStateChange?(.paused)
        XCTAssertEqual(viewModel.state, .paused)

        engine.onTimeUpdate?(12, 120)
        XCTAssertEqual(viewModel.currentTime, 12)
        XCTAssertEqual(viewModel.duration, 120)
    }

    // MARK: passthrough properties

    func test_audioSubtitleAndFormatProperties_passThroughFromEngine() {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [PlaybackTrack(id: 0, kind: .audio, displayTitle: "English", isSelected: true)]
        engine.subtitleTracks = [PlaybackTrack(id: 1, kind: .subtitle, displayTitle: "English (SDH)", isSelected: false)]
        engine.videoFormatDescription = "Dolby Vision"
        let (viewModel, _) = makeViewModel(engine: engine)

        XCTAssertEqual(viewModel.audioTracks, engine.audioTracks)
        XCTAssertEqual(viewModel.subtitleTracks, engine.subtitleTracks)
        XCTAssertEqual(viewModel.videoFormatDescription, "Dolby Vision")
    }

    func test_stats_passesThroughFromEngine() {
        let engine = FakePlaybackEngine()
        engine.stats.videoSize = "1920×804"
        engine.stats.bitrate = "12.4 Mbps"
        let (viewModel, _) = makeViewModel(engine: engine)

        XCTAssertEqual(viewModel.stats, engine.stats)
    }

    // MARK: refreshServerVersion() / refreshStreamingSession()

    func test_refreshServerVersion_fetchesOnceThenCaches() async {
        let (viewModel, _) = makeViewModel()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/System/Info/Public" else {
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
            requestCount += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(version: "10.9.7"))
        }

        await viewModel.refreshServerVersion()
        await viewModel.refreshServerVersion()

        XCTAssertEqual(viewModel.serverVersion, "10.9.7")
        XCTAssertEqual(requestCount, 1, "A second call shouldn't re-fetch a value that can't change mid-session")
    }

    func test_refreshStreamingSession_directPlay_populatesPlayMethodWithNoTranscodingInfo() async {
        let (viewModel, _) = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Sessions" else {
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
            let session = SessionInfoDto(
                id: "sess-1", deviceId: DeviceIdentity.deviceID,
                playState: PlayStateInfoDto(mediaSourceId: "src-1", playMethod: "DirectStream")
            )
            return try MockURLProtocol.encodedJSONResponse(for: request, value: [session])
        }

        await viewModel.refreshStreamingSession()

        XCTAssertEqual(viewModel.streamingSession?.playState?.playMethod, "DirectStream")
        XCTAssertNil(viewModel.streamingSession?.transcodingInfo)
    }

    func test_refreshStreamingSession_transcoding_populatesLiveTranscodingParameters() async {
        let (viewModel, _) = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/Sessions" else {
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
            let session = SessionInfoDto(
                id: "sess-1", deviceId: DeviceIdentity.deviceID,
                playState: PlayStateInfoDto(mediaSourceId: "src-1", playMethod: "Transcode"),
                transcodingInfo: TranscodingInfoDto(
                    audioCodec: "aac", videoCodec: "h264", bitrate: 8_000_000,
                    completionPercentage: 42, transcodeReasons: ["VideoBitrateNotSupported"]
                )
            )
            return try MockURLProtocol.encodedJSONResponse(for: request, value: [session])
        }

        await viewModel.refreshStreamingSession()

        XCTAssertEqual(viewModel.streamingSession?.playState?.playMethod, "Transcode")
        XCTAssertEqual(viewModel.streamingSession?.transcodingInfo?.videoCodec, "h264")
        XCTAssertEqual(viewModel.streamingSession?.transcodingInfo?.transcodeReasons, ["VideoBitrateNotSupported"])
    }

    func test_refreshStreamingSession_requestFails_leavesStreamingSessionNil() async {
        let (viewModel, _) = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        await viewModel.refreshStreamingSession()

        XCTAssertNil(viewModel.streamingSession, "A failed request should leave the last known value (nil, here) rather than crash/throw")
    }
}
