import SwiftUI
@testable import Dionysus

/// A controllable, recording `PlaybackEngine` fake — this is exactly what
/// `PlaybackEngine` exists for per `CLAUDE.md`'s Architecture notes ("useful
/// ... for swapping in a fake implementation"), just used from a test target
/// instead of a SwiftUI preview. `PreviewPlaybackEngine` (`#if DEBUG`) plays
/// the same role for previews, but its canned behavior (always succeeds,
/// fixed duration) doesn't give tests the control they need — this one
/// records every call and lets tests inject failures.
@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)?
    var onSourceTimeUpdate: ((TimeInterval) -> Void)?
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var videoFormatDescription: String?
    var videoNaturalSize: CGSize?
    var zoomMode: VideoZoomMode = .fit
    var stats = PlaybackStats(
        videoSize: nil,
        frameRate: nil,
        bitrate: nil,
        sourceColorFormat: "SDR",
        displayColorFormat: "SDR",
        videoDecoder: nil,
        audioDecoder: nil,
        audioChannels: nil,
        backend: "None",
        bufferedSeconds: nil,
        bufferedBytes: nil,
        currentTime: 0,
        duration: 0
    )

    /// Set before calling `load` to make it throw instead of succeeding.
    var loadError: Error?

    private(set) var loadedURLs: [URL] = []
    /// Recorded alongside each `loadedURLs` entry, same index — the
    /// `externalSubtitles` list `load(url:externalSubtitles:)` was called
    /// with, for tests asserting `PlayerViewModel.start()` built the right
    /// sidecar list from a `MediaSourceInfo`'s external `MediaStream`s.
    private(set) var loadedExternalSubtitles: [[ExternalSubtitleSource]] = []
    /// Recorded alongside each `loadedURLs` entry, same index — the
    /// `knownAtmosAudioTrackIndices` set `load(url:externalSubtitles:
    /// knownAtmosAudioTrackIndices:)` was called with, for tests asserting
    /// `PlayerViewModel.start()` derived the right set from a
    /// `MediaSourceInfo`'s audio `MediaStream`s' `audioSpatialFormat`.
    private(set) var loadedAtmosAudioTrackIndices: [Set<Int>] = []
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var togglePlayPauseCallCount = 0
    private(set) var seekedTimes: [TimeInterval] = []
    private(set) var stopCallCount = 0
    private(set) var selectedAudioTrackIDs: [Int] = []
    private(set) var selectedSubtitleTrackIDs: [Int?] = []
    private(set) var startPictureInPictureCallCount = 0
    private(set) var stopPictureInPictureCallCount = 0

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
        if let loadError { throw loadError }
        loadedURLs.append(url)
        loadedExternalSubtitles.append(externalSubtitles)
        loadedAtmosAudioTrackIndices.append(knownAtmosAudioTrackIndices)
    }

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }
    func togglePlayPause() { togglePlayPauseCallCount += 1 }
    func seek(to time: TimeInterval) async { seekedTimes.append(time) }
    func stop() { stopCallCount += 1 }
    func selectAudioTrack(id: Int) { selectedAudioTrackIDs.append(id) }
    func selectSubtitleTrack(id: Int?) { selectedSubtitleTrackIDs.append(id) }
    func startPictureInPicture() { startPictureInPictureCallCount += 1 }
    func stopPictureInPicture() { stopPictureInPictureCallCount += 1 }

    func makeSurface() -> AnyView { AnyView(EmptyView()) }
}
