#if DEBUG
import SwiftUI
import UIKit

/// Fake `PlaybackEngine` for SwiftUI previews and UI tests, so `PlayerView`
/// can run without a real AetherEngine instance or network access.
///
/// Shared between the two on purpose. A UI test needs exactly what a preview
/// needs — canned tracks, canned stats, no decode — plus a clock, so this
/// grew `advancesTime` rather than the app gaining a third fake alongside
/// this one and `DionysusPlayerTests`' `FakePlaybackEngine`. See
/// `PlaybackEngineFactory`, which is what hands this to `PlayerView`.
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
    /// Set before triggering a preview's `load(...)` to preview the error
    /// UI (`ErrorStateView`'s Retry-vs-Close branch in `PlayerView`)
    /// instead of the default always-succeeds behavior below.
    var simulatedFailure: PlaybackFailure?

    /// Drives a real clock while playing, so `PlayerViewModel` receives the
    /// time updates the scrubber and the elapsed/remaining labels render
    /// from. Off by default: a preview wants a still frame, and a repeating
    /// timer in a preview canvas is just churn.
    var advancesTime = false

    /// Wall-clock seconds between ticks. Matches roughly what AetherEngine's
    /// own clock publisher emits, so a test that waits on the label changing
    /// waits about as long as it would against the real engine.
    private static let tickInterval: TimeInterval = 0.25

    private var currentTime: TimeInterval = 0
    private var ticker: Task<Void, Never>?

    deinit { ticker?.cancel() }
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
        route: "Loopback",
        bufferedSeconds: 24,
        bufferedBytes: 8_400_000,
        currentTime: 0,
        duration: 5400
    )

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool) async throws {
        if let simulatedFailure {
            onStateChange?(.failed(simulatedFailure))
            return
        }
        currentTime = 0
        onStateChange?(.playing)
        onTimeUpdate?(currentTime, duration)
        startTickingIfNeeded()
    }

    func play() {
        onStateChange?(.playing)
        startTickingIfNeeded()
    }

    func pause() {
        stopTicking()
        onStateChange?(.paused)
    }

    func togglePlayPause() {}

    func seek(to time: TimeInterval) async {
        currentTime = min(max(time, 0), duration)
        onTimeUpdate?(currentTime, duration)
        onSourceTimeUpdate?(currentTime)
    }

    func stop() {
        stopTicking()
        onStateChange?(.ended)
    }
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func setNowPlayingInfo(title: String, subtitle: String?, artwork: UIImage?) {}

    func makeSurface() -> AnyView {
        AnyView(Color.black)
    }

    // MARK: - Clock

    /// The fixed runtime this fake reports. Long enough that a scrub test
    /// has somewhere to scrub to, and unrelated to whatever item the app
    /// thinks it loaded — nothing here reads the URL.
    private var duration: TimeInterval { 5400 }

    private func startTickingIfNeeded() {
        guard advancesTime, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        currentTime = min(currentTime + Self.tickInterval, duration)
        onTimeUpdate?(currentTime, duration)
        onSourceTimeUpdate?(currentTime)
        if currentTime >= duration {
            stopTicking()
            onStateChange?(.ended)
        }
    }
}
#endif
