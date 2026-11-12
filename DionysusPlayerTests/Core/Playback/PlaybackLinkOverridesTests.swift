import XCTest
@testable import Dionysus

/// What a `dionysus://play` link asks of its session (#406).
final class PlaybackLinkOverridesTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://jf.local")!, accessToken: "tok")

    private func chapters(_ starts: [TimeInterval]) -> [Chapter] {
        starts.enumerated().map { index, start in
            Chapter(dto: ChapterInfoDto(startPositionTicks: Int64(start * 10_000_000), name: "C\(index + 1)"), index: index, itemID: "m1", images: images)
        }
    }

    private func track(_ id: Int, kind: PlaybackTrack.Kind = .audio, isExternal: Bool = false) -> PlaybackTrack {
        PlaybackTrack(id: id, kind: kind, title: "Track \(id)", metadata: nil, isSelected: false, codec: nil, isExternal: isExternal)
    }

    // MARK: - From a link

    func test_fromALink_carriesItsOptions_andSaysWhatItCouldntRead() {
        let options = DeepLink.PlaybackOptions(
            start: .chapter(2), mediaSourceID: "v2", audioStreamIndex: 1, subtitle: .off, showsStats: true
        )
        let overrides = PlaybackLinkOverrides(options, issues: [.unreadableAudio, .unknownSort, .unreadableStartTime])
        XCTAssertEqual(overrides, PlaybackLinkOverrides(
            start: .chapter(2), mediaSourceID: "v2", audioStreamIndex: 1, subtitle: .off, showsStats: true,
            notices: ["Couldn't read the audio track.", "Couldn't read the start time."]
        ))
        XCTAssertTrue(overrides.choosesTracks)
        XCTAssertFalse(overrides.isEmpty)
    }

    /// A plain link plays exactly as Play would.
    func test_aPlainLink_isEmpty() {
        let overrides = PlaybackLinkOverrides(DeepLink.PlaybackOptions(prefersDownload: true, playlistID: "p1"))
        XCTAssertTrue(overrides.isEmpty)
        XCTAssertFalse(overrides.choosesTracks)
    }

    // MARK: - Start

    func test_aTime_startsThere_unlessItsPastTheEnd() {
        let fits = PlaybackLinkOverrides.startSeconds(for: .time(90), chapters: [], duration: 600)
        XCTAssertEqual(fits.seconds, 90)
        XCTAssertNil(fits.notice)
        XCTAssertEqual(PlaybackLinkOverrides.startSeconds(for: .time(0), chapters: [], duration: 600).seconds, 0,
                       "t=0 is Restart")
        let past = PlaybackLinkOverrides.startSeconds(for: .time(600), chapters: [], duration: 600)
        XCTAssertNil(past.seconds)
        XCTAssertEqual(past.notice, "The start time is past the end.")
        XCTAssertEqual(PlaybackLinkOverrides.startSeconds(for: .time(9999), chapters: [], duration: nil).seconds, 9999,
                       "With no runtime the time is trusted")
    }

    func test_aChapter_isOneBased_andMissingOnesAreSaid() {
        let list = chapters([0, 300, 900])
        XCTAssertEqual(PlaybackLinkOverrides.startSeconds(for: .chapter(1), chapters: list, duration: nil).seconds, 0)
        XCTAssertEqual(PlaybackLinkOverrides.startSeconds(for: .chapter(3), chapters: list, duration: nil).seconds, 900)
        let missing = PlaybackLinkOverrides.startSeconds(for: .chapter(4), chapters: list, duration: nil)
        XCTAssertNil(missing.seconds)
        XCTAssertEqual(missing.notice, "This title has no chapter 4.")
        XCTAssertEqual(PlaybackLinkOverrides.startSeconds(for: .chapter(1), chapters: [], duration: nil).notice,
                       "This title has no chapter 1.")
    }

    // MARK: - Tracks

    /// Jellyfin numbers an external subtitle into the same sequence, so an
    /// audio stream after it is one higher than its container position.
    func test_audio_mapsJellyfinsIndexToTheEnginesTrack() {
        let streams = [
            MediaStream(index: 0, type: "Subtitle", codec: "subrip", isExternal: true),
            MediaStream(index: 1, type: "Video", codec: "hevc"),
            MediaStream(index: 2, type: "Audio", codec: "eac3"),
            MediaStream(index: 3, type: "Audio", codec: "aac"),
        ]
        let engine = [track(1), track(2)]
        XCTAssertEqual(PlaybackLinkOverrides.audioTrackID(forStreamIndex: 3, mediaStreams: streams, engineTracks: engine), 2)
        XCTAssertEqual(PlaybackLinkOverrides.audioTrackID(forStreamIndex: 2, mediaStreams: streams, engineTracks: engine), 1)
        XCTAssertNil(PlaybackLinkOverrides.audioTrackID(forStreamIndex: 1, mediaStreams: streams, engineTracks: engine),
                     "The video stream isn't an audio track")
        XCTAssertNil(PlaybackLinkOverrides.audioTrackID(forStreamIndex: 7, mediaStreams: streams, engineTracks: engine))
        XCTAssertNil(PlaybackLinkOverrides.audioTrackID(forStreamIndex: 3, mediaStreams: streams, engineTracks: [track(1)]),
                     "A stream the engine doesn't list")
    }

    /// A sidecar the player registered is the engine's external track in the
    /// same place; an embedded one is its container position.
    func test_subtitle_mapsSidecarsByOrderAndEmbeddedByPosition() {
        let streams = [
            MediaStream(index: 0, type: "Video", codec: "hevc"),
            MediaStream(index: 1, type: "Audio", codec: "eac3"),
            MediaStream(index: 2, type: "Subtitle", codec: "ass"),
            MediaStream(index: 3, type: "Subtitle", codec: "subrip", isExternal: true),
            MediaStream(index: 4, type: "Subtitle", codec: "subrip", isExternal: true),
        ]
        let sidecars = [streams[3], streams[4]]
        let engine = [track(2, kind: .subtitle), track(100, kind: .subtitle, isExternal: true), track(101, kind: .subtitle, isExternal: true)]
        func id(_ index: Int, sidecars: [MediaStream] = sidecars, engine: [PlaybackTrack] = engine) -> Int? {
            PlaybackLinkOverrides.subtitleTrackID(forStreamIndex: index, mediaStreams: streams, sidecars: sidecars, engineTracks: engine)
        }
        XCTAssertEqual(id(2), 2)
        XCTAssertEqual(id(3), 100)
        XCTAssertEqual(id(4), 101)
        XCTAssertNil(id(1), "An audio stream isn't a subtitle track")
        XCTAssertNil(id(9))
        XCTAssertNil(id(4, engine: [track(2, kind: .subtitle), track(100, kind: .subtitle, isExternal: true)]),
                     "Sidecars the engine didn't all list can't be paired")
    }

    // MARK: - Notices

    func test_noticesCombineIntoOneToast() {
        XCTAssertNil(PlaybackLinkOverrides.combined([]))
        XCTAssertEqual(PlaybackLinkOverrides.combined(["One.", "Two."]), "One. Two.")
    }

    // MARK: - Mode and bitrate (DEBUG builds only)

    /// The link's mode maps onto the Streaming setting's, and a mode or
    /// bitrate it couldn't read is said.
    func test_modeAndBitrate_fromALink() {
        let overrides = PlaybackLinkOverrides(
            DeepLink.PlaybackOptions(decisionMode: .direct, maxBitrate: 4_000_000),
            issues: [.unknownMode, .unreadableBitrate]
        )
        XCTAssertEqual(overrides.decisionMode, .directPlayAlways)
        XCTAssertEqual(overrides.maxBitrate, 4_000_000)
        XCTAssertTrue(overrides.overridesStreaming)
        XCTAssertEqual(overrides.notices, ["Couldn't read the mode.", "Couldn't read the bitrate."])
        XCTAssertEqual(PlaybackLinkOverrides(DeepLink.PlaybackOptions(decisionMode: .transcode)).decisionMode, .allowTranscoding)
        XCTAssertFalse(PlaybackLinkOverrides().overridesStreaming)
    }

    /// The link's mode and bitrate beat the stored ones; a bitrate alone
    /// negotiates even where the setting says Direct Play Always; with
    /// `mode=direct` a bitrate has nothing to cap, and that's said.
    func test_streaming_linkBeatsTheSettings() {
        func streaming(_ mode: StreamDecisionMode?, _ bitrate: Int?, stored: StreamDecisionMode) -> (StreamDecisionMode, Int?, String?) {
            var overrides = PlaybackLinkOverrides()
            overrides.decisionMode = mode
            overrides.maxBitrate = bitrate
            let result = overrides.streaming(storedMode: stored, storedMaxBitrate: 20_000_000)
            return (result.mode, result.maxBitrate, result.notice)
        }
        XCTAssertTrue(streaming(.directPlayAlways, nil, stored: .allowTranscoding) == (.directPlayAlways, nil, nil))
        XCTAssertTrue(streaming(.allowTranscoding, nil, stored: .directPlayAlways) == (.allowTranscoding, 20_000_000, nil))
        XCTAssertTrue(streaming(nil, 4_000_000, stored: .directPlayAlways) == (.allowTranscoding, 4_000_000, nil))
        XCTAssertTrue(streaming(nil, nil, stored: .directPlayAlways) == (.directPlayAlways, nil, nil))
        let ignored = streaming(.directPlayAlways, 4_000_000, stored: .allowTranscoding)
        XCTAssertEqual(ignored.0, .directPlayAlways)
        XCTAssertNil(ignored.1)
        XCTAssertEqual(ignored.2, "Direct play has no bitrate cap, so the bitrate is ignored.")
    }
}
