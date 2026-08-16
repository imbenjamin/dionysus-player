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
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    var audioTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .audio, title: "Dolby Digital Plus Atmos 7.1", metadata: "DD+ · Atmos · 7.1 · Default", isSelected: true),
        PlaybackTrack(id: 1, kind: .audio, title: "Director's Commentary", metadata: "English · AAC · Stereo · Commentary", isSelected: false)
    ]
    var subtitleTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .subtitle, title: "English", metadata: "Default", isSelected: false),
        PlaybackTrack(id: 1, kind: .subtitle, title: "English", metadata: "Hearing Impaired", isSelected: false)
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

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
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
    func startPictureInPicture() {}
    func stopPictureInPicture() {}

    func makeSurface() -> AnyView {
        AnyView(Color.black)
    }
}
#endif
