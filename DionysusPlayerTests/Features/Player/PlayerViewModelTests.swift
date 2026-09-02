import CoreGraphics
import XCTest
@testable import Dionysus

/// `PlayerViewModel` was previously untested — it's the one place that ties
/// the Jellyfin networking layer to a `PlaybackEngine`, so it's worth
/// pinning: resume-position seeking, the start-from-beginning override,
/// playback-progress reporting, that transport controls delegate straight
/// through to the engine, and that a `TrackPreferenceStore`-remembered
/// audio/subtitle choice is restored on `start()` (falling back to the
/// engine's own default/forced-subtitle selection when nothing's stored,
/// and skipping a stored id no longer present in the freshly loaded track
/// list). `FakePlaybackEngine` (Support/) stands in for AetherEngine.
@MainActor
final class PlayerViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.PlayerViewModelTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        ConnectivityMonitor.shared.reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeViewModel(
        itemID: String = "item-1",
        startFromBeginning: Bool = false,
        mediaSourceID: String? = nil,
        engine: FakePlaybackEngine = FakePlaybackEngine(),
        trackPreferenceStore: TrackPreferenceStore? = nil,
        nextUpPreferenceStore: NextUpPreferenceStore? = nil,
        streamPreferenceStore: StreamPreferenceStore? = nil,
        playbackQueue: [MediaItem] = []
    ) -> (PlayerViewModel, FakePlaybackEngine) {
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: "user-1", itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID,
            trackPreferenceStore: trackPreferenceStore ?? TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: nextUpPreferenceStore ?? NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: streamPreferenceStore ?? StreamPreferenceStore(defaults: defaults),
            playbackQueue: playbackQueue
        )
        return (viewModel, engine)
    }

    /// A `MediaItem` wrapping a bare `BaseItemDto` — enough for
    /// `playbackQueue`-mode tests, which only need `id`/`kind` to exercise
    /// `loadNextUpItem(for:images:)`'s index lookup; no image URLs involved.
    private func makeMediaItem(id: String, name: String, kind: BaseItemKind) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: id, name: name, type: kind), images: ImageURLBuilder(baseURL: baseURL, accessToken: nil))
    }

    /// `loadNextEpisode(for:images:)` resolves `nextEpisode` from a
    /// fire-and-forget `Task` `start()` kicks off but doesn't await — polls
    /// with a bounded timeout rather than asserting immediately after
    /// `start()` returns, since nothing guarantees that Task has actually
    /// run by then. Everything it awaits in these tests is a `MockURLProtocol`
    /// response with no artificial delay, so in practice this resolves
    /// within a poll or two; the timeout is just a safety net against a hang
    /// reading as a slow test instead of an infinite one.
    private func waitUntilNextEpisodeResolved(_ viewModel: PlayerViewModel, timeout: TimeInterval = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.nextEpisode == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Standard item/playbackInfo/session-start stubbing shared by most
    /// `start()` tests; `itemDto` varies per test (e.g. to add a resume
    /// position), everything else is boilerplate. Includes `/MediaSegments/
    /// {itemID}` (empty, unless overridden — see `mediaSegments`) since
    /// `start()` now fires that fire-and-forget alongside every other
    /// request here, same as `/Sessions/Playing`.
    private func stubStart(
        itemID: String = "item-1", itemDto: BaseItemDto, mediaSources: [MediaSourceInfo]? = nil,
        mediaSegments: [MediaSegmentDto] = []
    ) {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/\(itemID)/PlaybackInfo":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse(mediaSources: mediaSources, playSessionId: "sess-1"))
            case "/Sessions/Playing":
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            case "/MediaSegments/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: MediaSegmentDtoQueryResult(items: mediaSegments, totalRecordCount: mediaSegments.count)
                )
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

    // MARK: start() — streaming mode (Direct Play Always vs. Allow Transcoding)

    /// The default `StreamDecisionMode` (Allow Transcoding, since
    /// 2026-08-28 — see `StreamPreferenceStore.decisionMode`'s doc comment
    /// for why) — pins that a real `DeviceProfile` goes out on
    /// `/PlaybackInfo` with no Settings change needed, and that a response
    /// with no `transcodingUrl` (this stub's) still falls back to the plain
    /// direct-play path exactly as Direct Play Always would. The top-level
    /// `MaxStreamingBitrate` field stays absent here — it only appears once
    /// `StreamingMaxBitrate` isn't `.unlimited` (also the default) — but
    /// `DeviceProfile.MaxStreamingBitrate` is still present inside the
    /// nested profile regardless, since Jellyfin defaults an absent value
    /// there to a restrictive 8 Mbps server-side (see
    /// `DeviceProfileBuilder`'s own doc comment).
    func test_start_allowTranscoding_default_sendsDeviceProfileAndFallsBackToDirectPlayURL() async {
        let (viewModel, engine) = makeViewModel()
        var playbackInfoBody: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))
            case "/Items/item-1/PlaybackInfo":
                playbackInfoBody = try JSONSerialization.jsonObject(with: request.capturedHTTPBody ?? Data()) as? [String: Any]
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")], playSessionId: "sess-1")
                )
            case "/Sessions/Playing":
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            case "/MediaSegments/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        await viewModel.start()

        let deviceProfile = playbackInfoBody?["DeviceProfile"] as? [String: Any]
        XCTAssertNotNil(deviceProfile)
        XCTAssertEqual(deviceProfile?["MaxStreamingBitrate"] as? Int, 120_000_000)
        XCTAssertNil(playbackInfoBody?["MaxStreamingBitrate"])
        XCTAssertEqual(engine.loadedIsRemoteHLS, [false])
        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("Static=true"))
    }

    /// Direct Play Always must still be explicitly selectable — the
    /// resulting `/PlaybackInfo` request should be byte-for-byte identical
    /// to before server-side negotiation existed at all (no `DeviceProfile`/
    /// `MaxStreamingBitrate` keys), and the engine load always takes the
    /// plain direct-play path.
    func test_start_directPlayAlways_explicitlySelected_sendsNoDeviceProfileAndLoadsWithIsRemoteHLSFalse() async {
        defaults.set(StreamDecisionMode.directPlayAlways.rawValue, forKey: streamDecisionModeStorageKey)
        let (viewModel, engine) = makeViewModel()
        var playbackInfoBody: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))
            case "/Items/item-1/PlaybackInfo":
                playbackInfoBody = try JSONSerialization.jsonObject(with: request.capturedHTTPBody ?? Data()) as? [String: Any]
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")], playSessionId: "sess-1")
                )
            case "/Sessions/Playing":
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            case "/MediaSegments/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        await viewModel.start()

        XCTAssertNil(playbackInfoBody?["DeviceProfile"])
        XCTAssertNil(playbackInfoBody?["MaxStreamingBitrate"])
        XCTAssertEqual(engine.loadedIsRemoteHLS, [false])
        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("Static=true"))
    }

    /// "Allow Transcoding" mode, server response with no `transcodingUrl` —
    /// falls back to the exact same direct-play `streamURL` path as Direct
    /// Play Always.
    func test_start_allowTranscoding_withoutTranscodingUrl_fallsBackToDirectPlayURL() async {
        defaults.set(StreamDecisionMode.allowTranscoding.rawValue, forKey: streamDecisionModeStorageKey)
        let (viewModel, engine) = makeViewModel()
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(engine.loadedIsRemoteHLS, [false])
        XCTAssertTrue(engine.loadedURLs[0].absoluteString.contains("Static=true"))
    }

    /// "Allow Transcoding" mode, server response with a `transcodingUrl` —
    /// the server decided direct play wasn't possible; the engine should
    /// load the resolved HLS URL via the `nativeRemoteHLS` bypass rather
    /// than the direct-play `streamURL`.
    func test_start_allowTranscoding_withTranscodingUrl_usesRemoteHLSLoadPath() async {
        defaults.set(StreamDecisionMode.allowTranscoding.rawValue, forKey: streamDecisionModeStorageKey)
        let (viewModel, engine) = makeViewModel()
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mkv", transcodingUrl: "/videos/item-1/master.m3u8?PlaySessionId=sess-1")]
        )

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(engine.loadedIsRemoteHLS, [true])
        XCTAssertEqual(engine.loadedURLs.first?.absoluteString, "https://jellyfin.example.com/videos/item-1/master.m3u8?PlaySessionId=sess-1")
    }

    /// `PlaybackInfoResponse.playSessionId` should flow into
    /// `activePlaySessionID` and from there into `/Sessions/Playing`'s
    /// request body — the server needs it to track/kill the right
    /// transcode job. `stubStart` always returns `"sess-1"`, matching real
    /// Jellyfin servers issuing a session id on every `/PlaybackInfo` call
    /// regardless of negotiation.
    func test_start_populatesActivePlaySessionID_andThreadsIntoReportPlaybackStart() async {
        let (viewModel, _) = makeViewModel()
        var reportedPlaySessionId: String?
        struct DecodedProgressBody: Decodable { let PlaySessionId: String? }
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))
            case "/Items/item-1/PlaybackInfo":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")], playSessionId: "sess-1")
                )
            case "/Sessions/Playing":
                reportedPlaySessionId = try JSONDecoder().decode(DecodedProgressBody.self, from: request.capturedHTTPBody ?? Data()).PlaySessionId
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            case "/MediaSegments/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0))
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        await viewModel.start()

        XCTAssertEqual(viewModel.activePlaySessionID, "sess-1")
        XCTAssertEqual(reportedPlaySessionId, "sess-1")
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
            case "/MediaSegments/item-1":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: MediaSegmentDtoQueryResult(items: [], totalRecordCount: 0))
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

    /// The connectivity-loss retry path (`PlayerView`'s offline overlay)
    /// passes the last known `currentTime` here to resume in place — it
    /// should win over both the server's own last-known resume position
    /// and `startFromBeginning`, since this is recovering an
    /// already-started session, not an intentional "play from the top".
    func test_start_withResumeSecondsOverride_seeksThereIgnoringStartFromBeginningAndServerResumePosition() async {
        let (viewModel, engine) = makeViewModel(startFromBeginning: true)
        let dto = BaseItemDto(
            id: "item-1", name: "Arrival", type: .movie,
            runTimeTicks: 100 * 10_000_000, userData: UserItemDataDto(playbackPositionTicks: 30 * 10_000_000)
        )
        stubStart(itemDto: dto)

        await viewModel.start(resumeSeconds: 42)

        XCTAssertEqual(engine.seekedTimes, [42])
        XCTAssertEqual(engine.playCallCount, 1)
    }

    /// A retry (from either the generic error overlay or the offline
    /// screen) must not leave a stale error message on screen once
    /// `start()` succeeds again.
    func test_start_clearsAnyPreviousErrorMessage() async {
        let (viewModel, engine) = makeViewModel()
        engine.onStateChange?(.failed(PlaybackFailure(message: "boom")))
        XCTAssertNotNil(viewModel.errorMessage)
        let dto = BaseItemDto(id: "item-1", name: "Arrival", type: .movie)
        stubStart(itemDto: dto)

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
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

    /// `sourceAudioStream` is `PlaybackStatsOverlay`'s fallback source for
    /// "Source Channels" on a `nativeRemoteHLS` session, where AetherEngine
    /// never probes the source itself — should prefer the stream marked
    /// `isDefault`, not just the first audio stream on the source.
    func test_start_setsSourceAudioStreamToDefaultTrackNotFirst() async {
        let (viewModel, _) = makeViewModel()
        let firstAudio = MediaStream(index: 1, type: "Audio", isDefault: false, channelLayout: "stereo")
        let defaultAudio = MediaStream(index: 2, type: "Audio", isDefault: true, channelLayout: "5.1")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4", mediaStreams: [firstAudio, defaultAudio])]
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.sourceAudioStream?.index, 2)
        XCTAssertEqual(viewModel.sourceAudioStream?.channelLayout, "5.1")
    }

    /// No stream is marked `isDefault` — falls back to the first audio
    /// stream rather than leaving `sourceAudioStream` `nil`.
    func test_start_setsSourceAudioStreamToFirstWhenNoneIsDefault() async {
        let (viewModel, _) = makeViewModel()
        let firstAudio = MediaStream(index: 1, type: "Audio", channelLayout: "stereo")
        let secondAudio = MediaStream(index: 2, type: "Audio", channelLayout: "5.1")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4", mediaStreams: [firstAudio, secondAudio])]
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.sourceAudioStream?.index, 1)
    }

    /// The lock screen/Control Center Now Playing card should be populated
    /// as soon as the item resolves, not left blank until playback actually
    /// starts (or forever, on the AV1/software route which currently has no
    /// artwork-loading path of its own to race against) — see
    /// `PlaybackEngine.setNowPlayingInfo(title:subtitle:artwork:)`'s doc
    /// comment. Title/subtitle are what `start()` can set synchronously;
    /// artwork trails in via a separate `RemoteImageLoader` fetch
    /// (`loadNowPlayingArtwork(for:)`) not exercised here, so this only
    /// asserts the first (artwork == nil) call `start()` itself makes.
    func test_start_setsNowPlayingTitleAndSubtitleImmediately() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(itemDto: BaseItemDto(
            id: "item-1", name: "Arrival", type: .movie, productionYear: 2016, runTimeTicks: 116 * 60 * 10_000_000
        ))

        await viewModel.start()

        let call = try? XCTUnwrap(engine.nowPlayingInfoCalls.first)
        XCTAssertEqual(call?.title, "Arrival")
        XCTAssertEqual(call?.subtitle, "2016 \u{00B7} 1h 56m")
        XCTAssertNil(call?.artwork)
    }

    /// `isExternal == true` subtitle streams (Jellyfin sidecar files) should
    /// reach the engine as `ExternalSubtitleSource`s; an embedded stream on
    /// the same source shouldn't — it already arrives through the demuxer,
    /// re-registering it as external would double it up.
    func test_start_registersExternalSubtitleStreamsWithTheEngine() async {
        let (viewModel, engine) = makeViewModel()
        let embeddedSubtitle = MediaStream(index: 2, type: "Subtitle", codec: "hdmv_pgs_subtitle", language: "eng")
        let externalSubtitle = MediaStream(
            index: 3, type: "Subtitle", codec: "subrip", language: "spa", title: "Forced",
            isForced: true, isExternal: true
        )
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "The Amazing Spider-Man", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mkv", mediaStreams: [embeddedSubtitle, externalSubtitle])]
        )

        await viewModel.start()

        XCTAssertEqual(engine.loadedExternalSubtitles.count, 1)
        let registered = engine.loadedExternalSubtitles[0]
        XCTAssertEqual(registered.count, 1, "The embedded PGS stream shouldn't be re-registered as external")
        XCTAssertEqual(registered.first?.language, "spa")
        XCTAssertEqual(registered.first?.name, "Forced")
        XCTAssertEqual(registered.first?.isForced, true)
        XCTAssertEqual(registered.first?.formatHint, "subrip")
        let url = try? XCTUnwrap(registered.first?.url.absoluteString)
        XCTAssertTrue(url?.contains("/Videos/item-1/src-1/Subtitles/3/Stream.srt") ?? false, "Should be built from itemID/mediaSourceID/index/codec, not a server-provided deliveryUrl (unreliable — see subtitleURL's doc comment)")
        XCTAssertTrue(url?.contains("ApiKey=tok") ?? false, "The side-demuxer fetches this itself, so the token has to travel in the URL")
    }

    /// `MediaSourceInfo.id` missing (no resolved source at all) should skip
    /// external subtitle registration entirely rather than failing the
    /// load — external subtitles are a bonus, not a requirement to play.
    func test_start_noResolvedMediaSourceID_skipsExternalSubtitleRegistration() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [])

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(engine.loadedExternalSubtitles, [[]])
    }

    /// `MediaStream.audioSpatialFormat == "DolbyAtmos"` should reach the
    /// engine as a track-index hint — deliberately keyed off that
    /// server-reported field rather than the stream's codec/title, since
    /// AetherEngine's own `TrackInfo.isAtmos` can't detect Atmos on a
    /// TrueHD track (EAC3-only). A non-Atmos audio stream and a non-audio
    /// stream with the same field set shouldn't be swept in.
    func test_start_registersAtmosAudioTrackIndicesFromAudioSpatialFormat() async {
        let (viewModel, engine) = makeViewModel()
        let trueHDAtmos = MediaStream(index: 1, type: "Audio", codec: "truehd", audioSpatialFormat: "DolbyAtmos")
        let ddPlusPlain = MediaStream(index: 2, type: "Audio", codec: "eac3", audioSpatialFormat: "None")
        let notAudio = MediaStream(index: 3, type: "Subtitle", audioSpatialFormat: "DolbyAtmos")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Saving Private Ryan", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mkv", mediaStreams: [trueHDAtmos, ddPlusPlain, notAudio])]
        )

        await viewModel.start()

        XCTAssertEqual(engine.loadedAtmosAudioTrackIndices, [[1]])
    }

    /// Regression test for a real bug (found live, 2026-08-14, on a Saving
    /// Private Ryan source): Jellyfin numbers `isExternal == true` streams
    /// into the same index sequence as embedded ones even though they
    /// carry no bytes in the physical container AetherEngine demuxes, so a
    /// stream's reported `index` can run ahead of its true position in the
    /// file — an external subtitle at index 0 shifted every embedded audio
    /// stream's reported index one higher than AetherEngine's own
    /// numbering for the identical tracks. The hint set has to report the
    /// *physical* index (matching `TrackInfo.id`), not `MediaStream.index`
    /// verbatim, or the flag silently never matches any real track.
    func test_start_atmosAudioTrackIndices_correctsForPrecedingExternalStreams() async {
        let (viewModel, engine) = makeViewModel()
        let externalSubtitle = MediaStream(index: 0, type: "Subtitle", isExternal: true)
        let video = MediaStream(index: 1, type: "Video")
        let trueHDAtmos = MediaStream(index: 2, type: "Audio", codec: "truehd", audioSpatialFormat: "DolbyAtmos")
        let ddPlusAtmos = MediaStream(index: 3, type: "Audio", codec: "eac3", audioSpatialFormat: "DolbyAtmos")
        let ddPlusPlain = MediaStream(index: 4, type: "Audio", codec: "eac3", audioSpatialFormat: "None")
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Saving Private Ryan", type: .movie),
            mediaSources: [MediaSourceInfo(
                id: "src-1", container: "mkv",
                mediaStreams: [externalSubtitle, video, trueHDAtmos, ddPlusAtmos, ddPlusPlain]
            )]
        )

        await viewModel.start()

        // Jellyfin reports 2/3; AetherEngine's own physical numbering for
        // the same tracks (one external stream precedes them) is 1/2.
        XCTAssertEqual(engine.loadedAtmosAudioTrackIndices, [[1, 2]])
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

    /// A `CancellationError` from `engine.load(...)` — a superseded load,
    /// e.g. rapid next-episode navigation or backing out mid-load — is not
    /// a playback failure and must not flash a spurious error. See
    /// `AetherPlaybackEngine.load(...)`'s own doc comment for why this is
    /// filtered in `start()`'s catch rather than at that throw site.
    func test_start_engineLoadThrows_cancellationError_leavesErrorMessageNil() async {
        let engine = FakePlaybackEngine()
        engine.loadError = CancellationError()
        let (viewModel, _) = makeViewModel(engine: engine)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.failureCategory)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    /// A `PlaybackLoadFailure` thrown from `engine.load(...)` (AetherEngine
    /// classified the failure, e.g. a source refusal) must carry both its
    /// message and its category through to the view model, not just fall
    /// back to the generic "Playback failed to start." message.
    func test_start_engineLoadThrows_playbackLoadFailure_setsErrorMessageAndFailureCategoryFromIt() async {
        let engine = FakePlaybackEngine()
        engine.loadError = PlaybackLoadFailure(failure: PlaybackFailure(message: "The server refused this stream.", category: .refused))
        let (viewModel, _) = makeViewModel(engine: engine)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertEqual(viewModel.errorMessage, "The server refused this stream.")
        XCTAssertEqual(viewModel.failureCategory, .refused)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    /// AUDIO SUPPRESSION: the last-resort guard — if a `PlaybackRequest` for
    /// an audio item ever reaches `start()` (bypassing `AssetDetailView`'s
    /// own check), it must bail before ever asking the engine to load a
    /// stream, since `/Items/{itemId}` has no server-side type filter to
    /// rely on instead.
    func test_start_audioItem_setsErrorMessageAndNeverCallsEngineLoad() async {
        let (viewModel, engine) = makeViewModel()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/item-1":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDto(id: "item-1", name: "Bend", type: .audio, mediaType: "Audio")
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?") — an audio item should bail before playbackInfo/streamURL")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }

        await viewModel.start()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(engine.loadedURLs.isEmpty)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    // MARK: start() restores a remembered track preference

    /// A stored audio/subtitle choice (`TrackPreferenceStore`) should
    /// override whatever `engine.load(...)` just defaulted to — including
    /// any forced-subtitle auto-select a real engine would have already
    /// applied by the time `load()` returns.
    func test_start_appliesStoredAudioAndSubtitleTrackSelection() async {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [
            PlaybackTrack(id: 1, kind: .audio, title: "English", metadata: nil, isSelected: true),
            PlaybackTrack(id: 2, kind: .audio, title: "Spanish", metadata: nil, isSelected: false),
        ]
        engine.subtitleTracks = [PlaybackTrack(id: 5, kind: .subtitle, title: "English (Forced)", metadata: nil, isSelected: true)]
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "item-1", userID: "user-1")
        store.recordSubtitleSelection(.init(id: 5, title: "English (Forced)"), forItem: "item-1", userID: "user-1")
        let (viewModel, _) = makeViewModel(engine: engine, trackPreferenceStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertEqual(engine.selectedAudioTrackIDs, [2])
        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [5])
    }

    /// Subtitles explicitly turned off is as real a remembered choice as a
    /// specific track — should re-apply as `nil`, same as
    /// `selectSubtitleTrack(id: nil)`'s own meaning.
    func test_start_appliesStoredOffSubtitlePreference() async {
        let engine = FakePlaybackEngine()
        engine.subtitleTracks = [PlaybackTrack(id: 5, kind: .subtitle, title: "English (Forced)", metadata: nil, isSelected: true)]
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordSubtitleSelection(nil, forItem: "item-1", userID: "user-1")
        let (viewModel, _) = makeViewModel(engine: engine, trackPreferenceStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [nil])
    }

    /// A fresh item with no playback history should behave exactly as
    /// before this feature existed — nothing extra selected, so the
    /// engine's own default/forced-subtitle selection stands untouched.
    func test_start_withNoStoredPreference_doesNotSelectAnyTrack() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertTrue(engine.selectedAudioTrackIDs.isEmpty)
        XCTAssertTrue(engine.selectedSubtitleTrackIDs.isEmpty)
    }

    /// A stored id that no longer matches the freshly loaded track list — a
    /// different version resolved than the one the preference was recorded
    /// against, say — should be skipped rather than passed through to the
    /// engine with a now-meaningless index.
    func test_start_ignoresStoredTrackIDsNotInTheLoadedTrackList() async {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [PlaybackTrack(id: 1, kind: .audio, title: "English", metadata: nil, isSelected: true)]
        engine.subtitleTracks = []
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 99, title: "Spanish"), forItem: "item-1", userID: "user-1")
        store.recordSubtitleSelection(.init(id: 99, title: "English"), forItem: "item-1", userID: "user-1")
        let (viewModel, _) = makeViewModel(engine: engine, trackPreferenceStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertTrue(engine.selectedAudioTrackIDs.isEmpty)
        XCTAssertTrue(engine.selectedSubtitleTrackIDs.isEmpty)
    }

    /// The trickier case a bare id-existence check can't catch: the stored
    /// id is still present in the freshly loaded list, but now belongs to a
    /// different track (the layout reordered — a different version
    /// resolved, a re-mux — without the track *count* changing). The title
    /// carried alongside the id is what catches this: a mismatch means
    /// skip, same as the id being gone entirely.
    func test_start_ignoresStoredTrackID_whenItsCurrentTitleNoLongerMatches() async {
        let engine = FakePlaybackEngine()
        // Same id (2) as what's stored below, but it's French now, not the
        // Spanish track the preference was actually recorded against.
        engine.audioTracks = [
            PlaybackTrack(id: 1, kind: .audio, title: "English", metadata: nil, isSelected: true),
            PlaybackTrack(id: 2, kind: .audio, title: "French", metadata: nil, isSelected: false),
        ]
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "item-1", userID: "user-1")
        let (viewModel, _) = makeViewModel(engine: engine, trackPreferenceStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie))

        await viewModel.start()

        XCTAssertTrue(engine.selectedAudioTrackIDs.isEmpty, "id 2 exists, but it's not the same track anymore")
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

    /// Every user-driven pick should also land in `TrackPreferenceStore`
    /// (alongside the track's own title — see `TrackPreferenceStore
    /// .TrackChoice`'s doc comment) so a later `start()` on this item can
    /// restore it — see the `start()` restore tests above.
    func test_selectAudioAndSubtitleTracks_alsoPersistToTheTrackPreferenceStore() {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [PlaybackTrack(id: 2, kind: .audio, title: "Spanish", metadata: nil, isSelected: false)]
        engine.subtitleTracks = [PlaybackTrack(id: 5, kind: .subtitle, title: "English", metadata: nil, isSelected: false)]
        let store = TrackPreferenceStore(defaults: defaults)
        let (viewModel, _) = makeViewModel(engine: engine, trackPreferenceStore: store)

        viewModel.selectAudioTrack(id: 2)
        viewModel.selectSubtitleTrack(id: 5)

        let selection = store.selection(forItem: "item-1", userID: "user-1")
        XCTAssertEqual(selection?.audioTrack, .init(id: 2, title: "Spanish"))
        XCTAssertEqual(selection?.subtitlePreference, .track(.init(id: 5, title: "English")))
    }

    /// Turning subtitles off is itself a rememberable choice — no track to
    /// look up a title for, so it should persist unconditionally.
    func test_selectSubtitleTrack_withNil_alsoPersistsOffToTheTrackPreferenceStore() {
        let store = TrackPreferenceStore(defaults: defaults)
        let (viewModel, _) = makeViewModel(trackPreferenceStore: store)

        viewModel.selectSubtitleTrack(id: nil)

        XCTAssertEqual(store.selection(forItem: "item-1", userID: "user-1")?.subtitlePreference, .off)
    }

    func test_setZoomMode_delegatesToEngine() {
        let (viewModel, engine) = makeViewModel()
        viewModel.setZoomMode(.fill)
        XCTAssertEqual(engine.zoomMode, .fill)
    }

    func test_startPictureInPicture_delegatesToEngine() {
        let (viewModel, engine) = makeViewModel()
        viewModel.startPictureInPicture()
        XCTAssertEqual(engine.startPictureInPictureCallCount, 1)
    }

    // MARK: scrub thumbnails (Jellyfin Trickplay)

    func test_scrubThumbnail_beforeStart_returnsNil() async {
        let (viewModel, _) = makeViewModel()
        XCTAssertFalse(viewModel.supportsScrubThumbnails)
        let result = await viewModel.scrubThumbnail(atSeconds: 10)
        XCTAssertNil(result)
    }

    func test_start_dtoWithMatchingTrickplayEntry_resolvesSupportsScrubThumbnails() async {
        let (viewModel, _) = makeViewModel()
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 1017, interval: 10000, bandwidth: 14011)
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie, trickplay: ["src-1": ["320": info]]),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")]
        )

        await viewModel.start()

        XCTAssertTrue(viewModel.supportsScrubThumbnails)
    }

    func test_start_dtoWithNoTrickplayEntryForResolvedMediaSource_leavesSupportsScrubThumbnailsFalse() async {
        let (viewModel, _) = makeViewModel()
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 1017, interval: 10000, bandwidth: 14011)
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie, trickplay: ["some-other-media-source": ["320": info]]),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")]
        )

        await viewModel.start()

        XCTAssertFalse(viewModel.supportsScrubThumbnails)
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

    /// A close affordance (the top bar's X, or the offline screen's own
    /// Close button) must dismiss promptly even while offline — `stop()`
    /// used to always attempt `reportPlaybackStopped` regardless, which
    /// `sendRaw`'s own 20s timeout race turned into a real, user-visible
    /// stall on every close path while genuinely offline (confirmed live,
    /// 2026-08-24): tapping Close read as completely unresponsive. Fails
    /// loudly (via a request handler that throws) rather than merely
    /// asserting the field-of-interest, so a regression that reintroduces
    /// the network call shows up as a hard failure here, not just a slow
    /// test.
    func test_stop_whileOffline_skipsNetworkCallAndStillStopsEngine() async {
        let (viewModel, engine) = makeViewModel()
        ConnectivityMonitor.shared.reportFailure()
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        await viewModel.stop()

        XCTAssertEqual(engine.stopCallCount, 1)
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

    /// Previously a terminal engine failure was silent: `state` updated,
    /// but nothing derived `errorMessage` from it, so `PlayerView`'s error
    /// overlay (which only ever reads `errorMessage`) never appeared —
    /// the video just froze with no spinner and no message. This pins the
    /// fix: a `.failed` state reaching `onStateChange` — not just a thrown
    /// error from `start()` — must populate `errorMessage` too.
    /// `ConnectivityMonitor.shared.isOffline` at that same moment is what
    /// `PlayerView` separately reads to decide between the shared offline
    /// screen and the generic error view — a SwiftUI view concern, so it's
    /// not re-asserted here.
    func test_engineFailedState_setsErrorMessage() {
        let (viewModel, engine) = makeViewModel()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.failureCategory)

        let failure = PlaybackFailure(message: "Source read failed (code 5)", category: .refused)
        engine.onStateChange?(.failed(failure))

        XCTAssertEqual(viewModel.state, .failed(failure))
        XCTAssertEqual(viewModel.errorMessage, "Source read failed (code 5)")
        XCTAssertEqual(viewModel.failureCategory, .refused)
    }

    func test_pictureInPictureCallbacks_updateViewModelState() {
        let (viewModel, engine) = makeViewModel()
        XCTAssertFalse(viewModel.isPictureInPicturePossible)
        XCTAssertFalse(viewModel.isPictureInPictureActive)

        engine.onPictureInPicturePossibleChange?(true)
        XCTAssertTrue(viewModel.isPictureInPicturePossible)

        engine.onPictureInPictureActiveChange?(true)
        XCTAssertTrue(viewModel.isPictureInPictureActive)

        engine.onPictureInPictureActiveChange?(false)
        XCTAssertFalse(viewModel.isPictureInPictureActive)
    }

    // MARK: passthrough properties

    func test_audioSubtitleAndFormatProperties_passThroughFromEngine() {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [PlaybackTrack(id: 0, kind: .audio, title: "English", metadata: "Default", isSelected: true)]
        engine.subtitleTracks = [PlaybackTrack(id: 1, kind: .subtitle, title: "English", metadata: "Hearing Impaired", isSelected: false)]
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

    // MARK: isOfflinePlayback

    /// The flip side of `PlayerViewModelOfflineTests
    /// .test_isOfflinePlayback_trueForADownloadedItemSession` — a live
    /// (non-downloaded) session must report `false`, or
    /// `PlaybackStatsOverlay`'s Streaming section would wrongly show
    /// "Download" for a real live stream.
    func test_isOfflinePlayback_falseForALiveSession() {
        let (viewModel, _) = makeViewModel()
        XCTAssertFalse(viewModel.isOfflinePlayback)
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

    // MARK: "Up Next" — nextEpisode resolution and nextUpSecondsRemaining

    /// Routes an episode's full `start()` flow (item/playbackInfo/session,
    /// same as `stubStart`) plus the `nextEpisode(...)` lookup's own
    /// `/Shows/.../Episodes` request — everything `loadNextEpisode(for:
    /// images:)` needs to resolve `nextEpisode` for a two-episode season.
    private func stubStartWithNextEpisode(
        itemID: String = "ep-1", nextEpisodeID: String = "ep-2", mediaSegments: [MediaSegmentDto] = []
    ) {
        let itemDto = BaseItemDto(
            id: itemID, name: "Episode One", type: .episode, runTimeTicks: 100 * 10_000_000,
            seriesId: "series-1", seasonId: "season-1", indexNumber: 1
        )
        let nextEpisodeDto = BaseItemDto(id: nextEpisodeID, name: "Episode Two", type: .episode, seriesId: "series-1", seasonId: "season-1", indexNumber: 2)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Users/user-1/Items/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: itemDto)
            case "/Items/\(itemID)/PlaybackInfo":
                return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")], playSessionId: "sess-1"))
            case "/Sessions/Playing":
                return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
            case "/Shows/series-1/Episodes":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: BaseItemDtoQueryResult(items: [itemDto, nextEpisodeDto], totalRecordCount: 2)
                )
            case "/MediaSegments/\(itemID)":
                return try MockURLProtocol.encodedJSONResponse(
                    for: request, value: MediaSegmentDtoQueryResult(items: mediaSegments, totalRecordCount: mediaSegments.count)
                )
            default:
                XCTFail("unexpected request to \(request.url?.path ?? "?")")
                return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
            }
        }
    }

    func test_start_episodeWithNextEpisode_resolvesNextEpisode() async {
        let (viewModel, _) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        XCTAssertEqual(viewModel.nextEpisode?.id, "ep-2")
    }

    /// `loadNextEpisode(for:images:)` guards on `kind == .episode` before
    /// firing anything — a Movie should never even attempt the lookup.
    /// `stubStart`'s `default: XCTFail` doubles as the assertion here: if
    /// this guard were missing, the unstubbed `/Shows/.../Episodes` request
    /// would fail the test instead of `nextEpisode` just staying `nil`.
    func test_start_movie_neverResolvesNextEpisode() async {
        let (viewModel, _) = makeViewModel()
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(viewModel.nextEpisode)
    }

    // MARK: playbackQueue (Playlist) mode

    /// `playbackQueue` mode resolves `nextEpisode` by a plain local index
    /// lookup — no `/Shows/.../Episodes` network call at all, unlike the
    /// per-series episode path above. `stubStart`'s `default: XCTFail`
    /// doubles as that assertion: if this fell through to the episode path
    /// instead, the unstubbed request would fail the test.
    func test_loadNextUpItem_nonEmptyQueue_resolvesNextItemByIndexWithNoNetworkCall() async {
        let queue = [
            makeMediaItem(id: "item-1", name: "Toy Story", kind: .movie),
            makeMediaItem(id: "item-2", name: "Cars", kind: .movie),
        ]
        let (viewModel, _) = makeViewModel(itemID: "item-1", playbackQueue: queue)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Toy Story", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()

        XCTAssertEqual(viewModel.nextEpisode?.id, "item-2")
    }

    /// The last item in the queue has nothing after it.
    func test_loadNextUpItem_lastItemInQueue_leavesNextEpisodeNil() async {
        let queue = [
            makeMediaItem(id: "item-1", name: "Toy Story", kind: .movie),
            makeMediaItem(id: "item-2", name: "Cars", kind: .movie),
        ]
        let (viewModel, _) = makeViewModel(itemID: "item-2", playbackQueue: queue)
        stubStart(itemID: "item-2", itemDto: BaseItemDto(id: "item-2", name: "Cars", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()

        XCTAssertNil(viewModel.nextEpisode)
    }

    /// Queue mode wins outright even for an Episode reached via a
    /// playlist — regression guard against silently falling back to the
    /// per-series `nextEpisode(...)` API path (which would need
    /// `seriesId`/`seasonId` and a `/Shows/.../Episodes` stub neither of
    /// which this test provides; `stubStart`'s `default: XCTFail` would
    /// catch that fallback happening).
    func test_loadNextUpItem_queueContainingEpisode_resolvesViaIndexNotEpisodeAPI() async {
        let queue = [
            makeMediaItem(id: "ep-1", name: "Pilot", kind: .episode),
            makeMediaItem(id: "movie-1", name: "Toy Story", kind: .movie),
        ]
        let (viewModel, _) = makeViewModel(itemID: "ep-1", playbackQueue: queue)
        stubStart(itemID: "ep-1", itemDto: BaseItemDto(id: "ep-1", name: "Pilot", type: .episode, seriesId: "series-1", seasonId: "season-1"), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])

        await viewModel.start()

        XCTAssertEqual(viewModel.nextEpisode?.id, "movie-1")
    }

    func test_nextUpSecondsRemaining_withinCountdownWindow_reportsRemainingSeconds() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(100, 300) // 200s from the end — outside the default 30s window
        XCTAssertNil(viewModel.nextUpSecondsRemaining)

        engine.onTimeUpdate?(295, 300) // 5s from the end — inside it
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)
    }

    /// Same truncation fix as the end-credits-segment case (see
    /// `test_nextUpSecondsRemaining_fractionalRemaining_truncatesRatherThanRoundsUp_matchingScrubberLabel`) —
    /// this duration-relative branch went through the identical
    /// `.rounded(.up)` → `Int(remaining)` change.
    func test_nextUpSecondsRemaining_fractionalRemaining_noEndCreditsSegment_alsoTruncates() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(293.6, 300) // 6.4s from the end
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 6, "Should truncate, not round up to 7")
    }

    /// Pins a live bug (2026-08-17): `nextUpSecondsRemaining` used to
    /// exclude `remaining == 0` (a strict `remaining > 0` guard), so the
    /// value jumped straight from `1` to `nil` and never actually reported
    /// `0` — silently breaking `PlayerView`'s `.onChange(of:
    /// nextUpSecondsRemaining)` auto-advance trigger, which only fires on
    /// an exact `0`. Also covers the real, separately-observed symptom
    /// that made it obvious: `currentTime` overshooting `duration` (the
    /// transport clock kept advancing past the item's real end) — this
    /// must clamp at `0` rather than go negative-and-`nil` in that case
    /// too, not just land on exactly `0` when the numbers line up evenly.
    func test_nextUpSecondsRemaining_reachesExactlyZero_ratherThanJumpingToNil() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(300, 300) // exactly at the end
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 0)

        engine.onTimeUpdate?(301, 300) // the clock overshooting duration, as observed live
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 0, "Should clamp at 0, not go negative and drop to nil")
    }

    func test_dismissNextUp_staysNilEvenAfterScrubbingBackIntoTheWindow() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(295, 300)
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)

        viewModel.dismissNextUp()
        XCTAssertNil(viewModel.nextUpSecondsRemaining)

        // Scrubbing back out and into the window again shouldn't resurrect it.
        engine.onTimeUpdate?(100, 300)
        engine.onTimeUpdate?(298, 300)
        XCTAssertNil(viewModel.nextUpSecondsRemaining)
    }

    func test_nextUpSecondsRemaining_countdownOff_neverReportsRemainingSeconds() async {
        defaults.set(NextUpCountdownPreference.off.rawValue, forKey: nextUpCountdownStorageKey)
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(295, 300)
        XCTAssertNil(viewModel.nextUpSecondsRemaining)
    }

    /// Pins a live bug (2026-08-17, ultrareview finding): auto-advancing
    /// while in Picture in Picture tore down the engine (and the
    /// `AVPictureInPictureController` it owns) out from under the user's
    /// PiP window. Suppressed for as long as `isPictureInPictureActive` is
    /// true, and recomputes correctly the moment it goes back to `false`
    /// (still within the window here) rather than staying stuck suppressed.
    func test_nextUpSecondsRemaining_suppressedWhilePictureInPictureActive() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode()

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)

        engine.onTimeUpdate?(295, 300)
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)

        engine.onPictureInPictureActiveChange?(true)
        XCTAssertNil(viewModel.nextUpSecondsRemaining)

        engine.onPictureInPictureActiveChange?(false)
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)
    }

    // MARK: Skippable segments

    func test_start_loadsMediaSegments() async {
        let (viewModel, _) = makeViewModel()
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")],
            mediaSegments: [
                MediaSegmentDto(id: "seg-intro", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000)
            ]
        )

        await viewModel.start()
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        XCTAssertEqual(viewModel.mediaSegments.first?.kind, .intro)
    }

    func test_currentSkipSegment_returnsSegmentContainingCurrentTime_elseNil() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")],
            mediaSegments: [
                MediaSegmentDto(id: "seg-intro", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000)
            ]
        )

        await viewModel.start()
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        engine.onTimeUpdate?(30, 300) // inside the intro
        XCTAssertEqual(viewModel.currentSkipSegment?.kind, .intro)

        engine.onTimeUpdate?(90, 300) // past it
        XCTAssertNil(viewModel.currentSkipSegment)
    }

    /// Jellyfin has no separate "opening credits" vs. "closing credits"
    /// segment type — an item with a mid-content credits roll *and* true
    /// end credits reports two `.outro` segments. Only the later one is
    /// "the end credits"; the earlier one still gets a plain skip button,
    /// even with a resolved `nextEpisode`.
    func test_currentSkipSegment_multipleOutroSegments_onlyTheLastDefersToNextUp() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro-early", itemId: "ep-1", type: .outro, startTicks: 100 * 10_000_000, endTicks: 110 * 10_000_000),
            MediaSegmentDto(id: "seg-outro-end", itemId: "ep-1", type: .outro, startTicks: 290 * 10_000_000, endTicks: 300 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        engine.onTimeUpdate?(105, 300) // inside the earlier, non-terminal outro
        XCTAssertEqual(viewModel.currentSkipSegment?.id, "seg-outro-early", "An earlier Outro segment isn't the end credits and should still show a plain skip button")

        engine.onTimeUpdate?(295, 300) // inside the true end credits
        XCTAssertNil(viewModel.currentSkipSegment, "The end-credits segment defers to the Up Next card instead of showing its own skip button")
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)
    }

    /// Confirmed with the user (2026-08-17): the end-credits segment's own
    /// start time fully replaces the duration-relative Up Next trigger —
    /// even when the segment starts *later* than the configured preference
    /// window would have fired on its own, nothing shows until the segment
    /// itself starts.
    func test_nextUpSecondsRemaining_endCreditsSegment_startsLaterThanPreferenceWindow_waitsForSegmentStart() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1") // default preference: 30s
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 280 * 10_000_000, endTicks: 300 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        engine.onTimeUpdate?(275, 300) // 25s from the end — inside the default 30s window, but before the segment starts
        XCTAssertNil(viewModel.nextUpSecondsRemaining, "The segment hasn't started yet, so the duration-relative window shouldn't apply")

        engine.onTimeUpdate?(280, 300) // the segment's own start
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 10)

        engine.onTimeUpdate?(285, 300) // 5s into the segment
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)
    }

    /// Symmetric case: a segment starting *earlier* than the configured
    /// preference window still fires right at the segment's start, rather
    /// than waiting for the preference's own (later) trigger point.
    func test_nextUpSecondsRemaining_endCreditsSegment_startsEarlierThanPreferenceWindow_firesAtSegmentStart() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1") // default preference: 30s
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 250 * 10_000_000, endTicks: 300 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        engine.onTimeUpdate?(250, 300) // the segment's own start — 50s from the end, well outside the 30s preference window
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 10, "The segment's start should win even though it's earlier than the configured preference window")
    }

    func test_nextUpTotalCountdownSeconds_reflectsEndCreditsOverride() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 280 * 10_000_000, endTicks: 300 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        XCTAssertEqual(viewModel.nextUpTotalCountdownSeconds, 10)

        engine.onTimeUpdate?(280, 300)
        XCTAssertEqual(viewModel.nextUpTotalCountdownSeconds, 10)
    }

    /// Pins a live bug (2026-08-18, confirmed with the user): scrubbing
    /// straight past where the end-credits countdown's own trigger point
    /// would already have elapsed used to compute an instantly-`0`
    /// `remaining` on landing — silently auto-advancing to the next
    /// episode with no countdown UI ever shown. A scrub landing anywhere
    /// inside the segment should always get a fresh countdown timed from
    /// wherever it actually landed, not from the segment's own start.
    func test_nextUpSecondsRemaining_scrubPastTriggerPoint_getsFreshCountdownInsteadOfInstantZero() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 60 * 10_000_000, endTicks: 120 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        engine.onTimeUpdate?(65, 120) // naturally entered the segment; anchored to 65
        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 10)

        // The user scrubs well past where a from-65 countdown would already
        // have hit 0 (65 + 10 = 75) — `seek(to:)` clears the stale anchor,
        // and the engine reporting the seek having landed re-anchors fresh
        // right there instead of computing a negative-then-clamped-`0`
        // remaining from the old one.
        viewModel.seek(to: 100)
        engine.onTimeUpdate?(100, 120)

        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 10, "Should restart a fresh countdown at the landing point, not jump straight to 0")
    }

    /// A scrub landing within the final 10 seconds of the item's own
    /// duration should count down only as far as the real end, not imply a
    /// target past it — same "or up to the end of the asset" requirement
    /// `nextUpTotalCountdownSeconds`'s ring reflects too.
    func test_nextUpSecondsRemaining_scrubIntoFinalTenSeconds_countsDownToTheRealEndOnly() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 60 * 10_000_000, endTicks: 125 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        viewModel.seek(to: 120) // 5s from the item's real end (125)
        engine.onTimeUpdate?(120, 125)

        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 5)
        XCTAssertEqual(viewModel.nextUpTotalCountdownSeconds, 5)
    }

    /// Pins a live bug (2026-08-18, confirmed with the user): a fractional
    /// `remaining` used to round *up*, reading one higher than the
    /// scrubber's own "time remaining" label (`PlayerControlsOverlay
    /// .endTimeText`, which truncates) for the entire time in between whole
    /// seconds — landing a scrub the scrubber itself would show as "0:06"
    /// remaining (6.4s truly remaining) showed `7` here instead of `6`.
    func test_nextUpSecondsRemaining_fractionalRemaining_truncatesRatherThanRoundsUp_matchingScrubberLabel() async {
        let (viewModel, engine) = makeViewModel(itemID: "ep-1")
        stubStartWithNextEpisode(mediaSegments: [
            MediaSegmentDto(id: "seg-outro", itemId: "ep-1", type: .outro, startTicks: 60 * 10_000_000, endTicks: 125 * 10_000_000)
        ])

        await viewModel.start()
        await waitUntilNextEpisodeResolved(viewModel)
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }

        viewModel.seek(to: 118.6) // 6.4s from the item's real end (125) — the scrubber itself would read "0:06"
        engine.onTimeUpdate?(118.6, 125)

        XCTAssertEqual(viewModel.nextUpSecondsRemaining, 6, "Should truncate to match the scrubber's own remaining-time label, not round up to 7")
    }

    /// `currentSkipSegment` must hide as soon as the button is tapped, not
    /// once `currentTime` actually catches up to the seek target — that gap
    /// can be a whole buffering spell's worth of time (confirmed with the
    /// user, 2026-08-17).
    func test_skipSegment_hidesCurrentSkipSegmentImmediately_beforeCurrentTimeCatchesUp() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")],
            mediaSegments: [
                MediaSegmentDto(id: "seg-intro", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000)
            ]
        )
        await viewModel.start()
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }
        engine.onTimeUpdate?(30, 300)
        let segment = viewModel.currentSkipSegment!

        viewModel.skipSegment(segment)

        // `currentTime` is still 30 — inside the segment's own range — but
        // the button should already be gone.
        XCTAssertNil(viewModel.currentSkipSegment)
    }

    func test_skipSegment_delegatesToEngineSeekAtSegmentEnd() async throws {
        let (viewModel, engine) = makeViewModel()
        let segment = PlaybackSegment(dto: MediaSegmentDto(id: "seg-1", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000))!

        viewModel.skipSegment(segment)

        try await waitUntil { engine.seekedTimes.contains(60) }
    }

    /// `SkipSegmentOverlay`'s swipe/close-button dismiss — same "hide the
    /// button immediately" contract as `skipSegment(_:)`'s own test above,
    /// via the same `skippedSegmentIDs` mechanism.
    func test_dismissSkipSegment_hidesCurrentSkipSegmentImmediately() async {
        let (viewModel, engine) = makeViewModel()
        stubStart(
            itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie),
            mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")],
            mediaSegments: [
                MediaSegmentDto(id: "seg-intro", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000)
            ]
        )
        await viewModel.start()
        try? await waitUntil { !viewModel.mediaSegments.isEmpty }
        engine.onTimeUpdate?(30, 300)
        let segment = viewModel.currentSkipSegment!

        viewModel.dismissSkipSegment(segment)

        XCTAssertNil(viewModel.currentSkipSegment)
    }

    /// Dismissing is not skipping — unlike `skipSegment(_:)`, it must never
    /// seek. Playback stays exactly where it was; only the button's own
    /// offer to skip goes away.
    func test_dismissSkipSegment_doesNotSeek() async {
        let (viewModel, engine) = makeViewModel()
        let segment = PlaybackSegment(dto: MediaSegmentDto(id: "seg-1", itemId: "item-1", type: .intro, startTicks: 0, endTicks: 60 * 10_000_000))!

        viewModel.dismissSkipSegment(segment)

        XCTAssertTrue(engine.seekedTimes.isEmpty)
    }
}
