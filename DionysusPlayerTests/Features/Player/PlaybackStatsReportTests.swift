import XCTest
@testable import Dionysus

@MainActor
final class PlaybackStatsReportTests: XCTestCase {
    private let stats = PlaybackStats(
        videoSize: "3840×1600", frameRate: "23.976 fps", bitrate: "38.2 Mbps",
        sourceColorFormat: "Dolby Vision (Profile 8)", displayColorFormat: "HDR10",
        videoDecoder: "VideoToolbox HEVC (HW)", audioDecoder: "AVPlayer", audioChannels: "5.1",
        backend: "Native", route: "Loopback", bufferedSeconds: 24, bufferedBytes: 8_400_000,
        currentTime: 0, duration: 5400, videoCodec: "HEVC Main 10", container: "Matroska",
        pixelFormat: "yuv420p10le (10-bit)", colorDescription: "BT.2020 · PQ", audioSampling: "48 kHz",
        liveBitrate: "38.4 Mbps", networkThroughput: "212.0 Mbps", frames: "0 dropped"
    )

    /// The rows and ids iOS's journeys read stay as they were.
    func test_video_keepsIOSsRowsInOrder() {
        let section = PlaybackStatsReport.video(stats, sourceVideoStream: nil)
        XCTAssertEqual(section.rows.prefix(4).map(\.label), ["Resolution", "Frame Rate", "Bitrate", "Codec"])
        XCTAssertEqual(section.rows.first { $0.label == "Codec" }?.value, "HEVC Main 10")
        XCTAssertTrue(section.rows.contains { $0.label == "Enhancement Layer" }, "Shown for a Dolby Vision source")
    }

    func test_audioDecoder_hasItsOwnID() {
        let section = PlaybackStatsReport.audio(stats, sourceAudioStream: nil, readings: .init())
        XCTAssertEqual(section.rows.first?.id, "Audio Decoder")
    }

    func test_playback_omitsZoomWhereThereIsNone() {
        XCTAssertTrue(PlaybackStatsReport.playback(stats, state: .playing, zoomMode: .fit).rows.contains { $0.label == "Zoom" })
        XCTAssertFalse(PlaybackStatsReport.playback(stats, state: .playing, zoomMode: nil).rows.contains { $0.label == "Zoom" })
    }

    func test_streaming_offlineIsOneDownloadRow() {
        let section = PlaybackStatsReport.streaming(isOffline: true, serverVersion: "10.11.11", session: nil)
        XCTAssertEqual(section.rows, [PlaybackStatsReport.Row("Play Method", "Download")])
    }

    func test_build_namesThePlatformsVersion() {
        let labels = PlaybackStatsReport.build().rows.map(\.label)
        #if os(tvOS)
        XCTAssertTrue(labels.contains("tvOS Version"))
        #else
        XCTAssertTrue(labels.contains("iOS Version"))
        #endif
    }

    /// iOS's default on both platforms: on in debug, off in release
    /// (Benjamin, 2026-10-07).
    func test_statsButtonDefault() {
        #if DEBUG
        XCTAssertTrue(showPlaybackStatsButtonEnabledDefault)
        #else
        XCTAssertFalse(showPlaybackStatsButtonEnabledDefault)
        #endif
    }
}
