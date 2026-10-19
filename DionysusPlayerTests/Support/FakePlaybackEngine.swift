import SwiftUI
import UIKit
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
    var onSubtitleTrackChange: ((Int?) -> Void)?
    var fontAttachments: [ASSFontAttachment] = []
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?
    var onPictureInPictureActiveChange: ((Bool) -> Void)?
    var onSourceTimeFollowsPictureChange: ((Bool) -> Void)?
    var onAudioOffsetAvailabilityChange: ((Bool) -> Void)?
    /// Settable so a test can flip the route; reports through the callback.
    var isAudioOffsetAvailable = false {
        didSet { onAudioOffsetAvailabilityChange?(isAudioOffsetAvailable) }
    }

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
        route: "None",
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
    /// Recorded alongside each `loadedURLs` entry, same index — the
    /// `isRemoteHLS` flag `load(...)` was called with, for tests asserting
    /// `PlayerViewModel.start()` chose the right load path (a plain
    /// direct-play URL vs. a server-chosen HLS transcode).
    private(set) var loadedIsRemoteHLS: [Bool] = []
    /// Recorded alongside each `loadedURLs` entry, same index — the
    /// `audioOffset` `load(...)` was given.
    private(set) var loadedAudioOffsets: [TimeInterval] = []
    private(set) var audioOffsetRequests: [TimeInterval] = []
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var togglePlayPauseCallCount = 0
    private(set) var seekedTimes: [TimeInterval] = []
    private(set) var stopCallCount = 0
    private(set) var selectedAudioTrackIDs: [Int] = []
    private(set) var selectedSubtitleTrackIDs: [Int?] = []
    private(set) var startPictureInPictureCallCount = 0
    private(set) var stopPictureInPictureCallCount = 0
    private(set) var nowPlayingInfoCalls: [(title: String, subtitle: String?, artwork: UIImage?)] = []

    /// Recorded alongside each `loadedURLs` entry, same index.
    private(set) var loadedSpatialAudio: [SpatialAudioRendering] = []
    /// Every `setSpatialAudio(_:)` that changed the value: the rebuilds.
    private(set) var spatialAudioReloads: [SpatialAudioRendering] = []
    private(set) var spatialAudio: SpatialAudioRendering = .off
    /// Audio switches and rebuilds in the order they reached the engine: on
    /// AetherEngine a switch is itself a rebuild, which a rebuild started
    /// after it cancels, so the order is what a test pins.
    private(set) var audioEvents: [AudioEvent] = []

    enum AudioEvent: Equatable {
        case selectAudioTrack(Int)
        case setSpatialAudio(SpatialAudioRendering)
    }

    func setSpatialAudio(_ rendering: SpatialAudioRendering) async throws {
        guard rendering != spatialAudio else { return }
        spatialAudio = rendering
        spatialAudioReloads.append(rendering)
        audioEvents.append(.setSpatialAudio(rendering))
    }

    func load(
        url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>,
        isRemoteHLS: Bool, audioOffset: TimeInterval, spatialAudio: SpatialAudioRendering
    ) async throws {
        if let loadError { throw loadError }
        loadedSpatialAudio.append(spatialAudio)
        self.spatialAudio = spatialAudio
        loadedURLs.append(url)
        loadedExternalSubtitles.append(externalSubtitles)
        loadedAtmosAudioTrackIndices.append(knownAtmosAudioTrackIndices)
        loadedIsRemoteHLS.append(isRemoteHLS)
        loadedAudioOffsets.append(audioOffset)
    }

    func setAudioOffset(_ seconds: TimeInterval) { audioOffsetRequests.append(seconds) }

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }
    func togglePlayPause() { togglePlayPauseCallCount += 1 }
    /// Runs inside `seek(to:)`, so a test can act mid-seek (e.g. cancel the
    /// task that called it).
    var onSeek: (() -> Void)?
    func seek(to time: TimeInterval) async {
        seekedTimes.append(time)
        onSeek?()
    }
    func stop() { stopCallCount += 1 }
    func selectAudioTrack(id: Int) {
        selectedAudioTrackIDs.append(id)
        audioEvents.append(.selectAudioTrack(id))
    }
    func selectSubtitleTrack(id: Int?) { selectedSubtitleTrackIDs.append(id) }
    /// Recorded rather than acted on: there is no AVPlayer here to hand the
    /// drawing to. Lets a test assert that libass taking over the paint also
    /// took the native rendition away from AVKit.
    private(set) var nativeSubtitleRenderingRequests: [Bool] = []
    /// Same, for the transcode route's capture-instead-of-deselect.
    private(set) var nativeSubtitleCaptureRequests: [Bool] = []

    func setNativeSubtitleRendering(_ active: Bool) {
        nativeSubtitleRenderingRequests.append(active)
    }

    func setNativeSubtitleCapture(_ active: Bool) {
        nativeSubtitleCaptureRequests.append(active)
    }

    func startPictureInPicture() { startPictureInPictureCallCount += 1 }
    func stopPictureInPicture() { stopPictureInPictureCallCount += 1 }
    func setNowPlayingInfo(title: String, subtitle: String?, artwork: UIImage?) {
        nowPlayingInfoCalls.append((title: title, subtitle: subtitle, artwork: artwork))
    }

    func makeSurface() -> AnyView { AnyView(EmptyView()) }
}
