#if DEBUG
import SwiftUI

/// Fake `PlaybackEngine` for SwiftUI previews, so `PlayerView` can be
/// previewed without a real AetherEngine instance or network access.
@MainActor
final class PreviewPlaybackEngine: PlaybackEngine {
    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)?
    var onSourceTimeUpdate: ((TimeInterval) -> Void)?

    var audioTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .audio, displayTitle: "English 5.1", isSelected: true),
        PlaybackTrack(id: 1, kind: .audio, displayTitle: "Commentary", isSelected: false)
    ]
    var subtitleTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .subtitle, displayTitle: "English", isSelected: false),
        PlaybackTrack(id: 1, kind: .subtitle, displayTitle: "English (SDH)", isSelected: false)
    ]
    var videoFormatDescription: String? = "Dolby Vision P8.1"
    var videoNaturalSize: CGSize? = CGSize(width: 3840, height: 1600)
    var zoomMode: VideoZoomMode = .fit
    var stats = PlaybackStats(
        videoSize: "3840×1600",
        frameRate: "23.976 fps",
        bitrate: "38.2 Mbps",
        sourceColorFormat: "Dolby Vision (Profile 8)",
        displayColorFormat: "HDR10",
        videoDecoder: "VideoToolbox HEVC (HW)",
        audioDecoder: "AVPlayer",
        audioChannels: "5.1",
        backend: "Native",
        bufferedSeconds: 24,
        bufferedBytes: 8_400_000,
        currentTime: 0,
        duration: 5400
    )

    func load(url: URL) async throws {
        onStateChange?(.playing)
        onTimeUpdate?(0, 5400)
    }

    func play() { onStateChange?(.playing) }
    func pause() { onStateChange?(.paused) }
    func togglePlayPause() {}
    func seek(to time: TimeInterval) async { onTimeUpdate?(time, 5400) }
    func stop() { onStateChange?(.ended) }
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int?) {}

    func makeSurface() -> AnyView {
        AnyView(Color.black)
    }
}
#endif
