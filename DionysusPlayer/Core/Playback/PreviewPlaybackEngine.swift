#if DEBUG
import SwiftUI
import UIKit

/// Fake `PlaybackEngine` for SwiftUI previews and UI tests, so `PlayerView`
/// can run without a real AetherEngine instance or network access.
///
/// Shared between the two: a UI test needs what a preview needs — canned tracks
/// and stats, no decode — plus a clock, so this grew `advancesTime` rather than
/// the app gaining a third fake. `PlaybackEngineFactory` hands it to
/// `PlayerView`.
@MainActor
final class PreviewPlaybackEngine: PlaybackEngine {
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
    private(set) var isAudioOffsetAvailable = false
    /// The last offset `load` or `setAudioOffset` was given, for previews.
    private(set) var audioOffsetSeconds: TimeInterval = 0

    var audioTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .audio, title: "Dolby Digital Plus Atmos 7.1", metadata: "DD+ · Atmos · 7.1 · Default", isSelected: true),
        PlaybackTrack(id: 1, kind: .audio, title: "Director's Commentary", metadata: "English · AAC · Stereo · Commentary", isSelected: false)
    ]
    var subtitleTracks: [PlaybackTrack] = [
        PlaybackTrack(id: 0, kind: .subtitle, title: "English", metadata: "Default",
                      isSelected: false, codec: "subrip"),
        PlaybackTrack(id: 1, kind: .subtitle, title: "English", metadata: "Hearing Impaired",
                      isSelected: false, codec: "subrip"),
        // An authored-ASS track, so the styled path has something to select.
        // Embedded and last, matching the fixture's own stream order — the
        // track/stream pairing is by ordinal among embedded ASS entries (see
        // `PlayerViewModel.jellyfinStream(forTrack:engineTracks:mediaStreams:)`).
        PlaybackTrack(id: 2, kind: .subtitle, title: "English", metadata: "Styled",
                      isSelected: false, codec: "ass"),
        // After the ASS track, so its ordinal among the fixture's streams and
        // the Apple TV panel's row numbers stay as they were.
        // Placed text cues (`placedCues`), as a WebVTT track with line and
        // position settings, or ASS with ASS/SSA Subtitles off, publishes them.
        PlaybackTrack(id: 3, kind: .subtitle, title: "English", metadata: "Signs",
                      isSelected: false, codec: "webvtt"),
        // A bitmap track (`imageCues`), as PGS, VobSub and DVB publish them.
        PlaybackTrack(id: 4, kind: .subtitle, title: "English", metadata: "PGS",
                      isSelected: false, codec: "pgssub")
    ]
    var videoFormatDescription: String? = "Dolby Vision P8.1"
    var videoNaturalSize: CGSize? = UITestConfiguration.scenario == .anamorphicVideo
        ? UITestFixtureIdentity.anamorphicVideoCodedSize : CGSize(width: 3840, height: 1600)
    var videoPixelAspectRatio: Double = UITestConfiguration.scenario == .anamorphicVideo
        ? UITestFixtureIdentity.anamorphicVideoPixelAspectRatio : 1
    var zoomMode: VideoZoomMode = .fit
    /// Set before a preview's `load(...)` to render the error UI —
    /// `ErrorStateView`'s Retry-versus-Close branch — instead of succeeding.
    var simulatedFailure: PlaybackFailure?

    /// Drives a real clock while playing, so `PlayerViewModel` gets the time
    /// updates the scrubber and labels render from. Off by default: a preview
    /// wants a still frame, not a repeating timer in the canvas.
    var advancesTime = false

    /// Wall-clock seconds between ticks, roughly AetherEngine's own cadence, so
    /// a test waiting on a label change waits about as long as it would live.
    private static let tickInterval: TimeInterval = 0.25

    private var currentTime: TimeInterval = 0
    private var ticker: Task<Void, Never>?
    private var isPlaying = false

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
        duration: 5400,
        videoCodec: "HEVC Main 10",
        container: "Matroska",
        pixelFormat: "yuv420p10le (10-bit)",
        colorDescription: "BT.2020 · PQ (SMPTE ST 2084) · BT.2020 NCL · Limited",
        audioSampling: "48 kHz",
        liveBitrate: "38.4 Mbps (avg 37.9)",
        networkThroughput: "212.0 Mbps",
        frames: "0 dropped"
    )

    /// What the last `load(...)` or `setSpatialAudio(_:)` asked for, for UI
    /// tests to read (nothing renders here).
    private(set) var spatialAudio: SpatialAudioRendering = .off
    private(set) var spatialAudioReloads: [SpatialAudioRendering] = []

    func setSpatialAudio(_ rendering: SpatialAudioRendering) async throws {
        guard rendering != spatialAudio else { return }
        spatialAudio = rendering
        spatialAudioReloads.append(rendering)
    }

    func load(
        url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>,
        isRemoteHLS: Bool, audioOffset: TimeInterval, spatialAudio: SpatialAudioRendering
    ) async throws {
        self.spatialAudio = spatialAudio
        if let simulatedFailure {
            onStateChange?(.failed(simulatedFailure))
            return
        }
        currentTime = 0
        isPlaying = true
        audioOffsetSeconds = audioOffset
        isAudioOffsetAvailable = UITestConfiguration.scenario != .audioOffsetUnavailable
        onAudioOffsetAvailabilityChange?(isAudioOffsetAvailable)
        onStateChange?(.playing)
        onTimeUpdate?(currentTime, duration)
        startTickingIfNeeded()
        if UITestConfiguration.scenario == .rebuffering { simulateRebuffer() }
        if UITestConfiguration.scenario == .reconnecting { simulateReconnect() }
        onPictureInPicturePossibleChange?(UITestConfiguration.scenario == .pictureInPicture)
    }

    /// The `reconnecting` scenario's dropped source: 2 s in, `.reconnecting`
    /// for 4 s with the clock stopped, then playing on.
    private func simulateReconnect() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isPlaying else { return }
            self.stopTicking()
            self.onStateChange?(.reconnecting)
            try? await Task.sleep(for: .seconds(4))
            guard self.isPlaying else { return }
            self.play()
        }
    }

    /// The `rebuffering` scenario's stall: 2 s in, `.buffering` for 3 s with
    /// the clock stopped, then playing on.
    private func simulateRebuffer() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isPlaying else { return }
            self.stopTicking()
            self.onStateChange?(.buffering)
            try? await Task.sleep(for: .seconds(3))
            guard self.isPlaying else { return }
            self.play()
        }
    }

    func play() {
        isPlaying = true
        onStateChange?(.playing)
        startTickingIfNeeded()
    }

    func pause() {
        isPlaying = false
        stopTicking()
        onStateChange?(.paused)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval, exact: Bool) async {
        // The `slowSeek` scenario: `.seeking` for 3 s before the seek lands,
        // with the clock stopped, as a long jump on a slow link;
        // `introBeforeResume` holds the resume seek the same way.
        if [.slowSeek, .introBeforeResume].contains(UITestConfiguration.scenario) {
            stopTicking()
            onStateChange?(.seeking)
            try? await Task.sleep(for: .seconds(3))
            onStateChange?(isPlaying ? .playing : .paused)
            if isPlaying { startTickingIfNeeded() }
        }
        currentTime = min(max(time, 0), duration)
        onTimeUpdate?(currentTime, duration)
        onSourceTimeUpdate?(currentTime)
    }

    func stop() {
        stopTicking()
        onStateChange?(.ended)
    }
    func selectAudioTrack(id: Int) {
        audioTracks = audioTracks.map { $0.selected($0.id == id) }
    }

    /// Unlike the audio counterpart this has to announce itself: the styled-ASS
    /// path hangs off `onSubtitleTrackChange`, so a no-op here would leave a UI
    /// test unable to reach it at all.
    ///
    /// It also publishes a cue, which is what `SubtitleOverlayView`'s own
    /// (non-libass) path renders — every SubRip and WebVTT track in the app,
    /// and an ASS track when ASS/SSA Subtitles is off. Without it that path
    /// paints nothing under the harness, so a test could only ever assert the
    /// *absence* of a styled frame — which passes just as happily on a bug that
    /// drops the track altogether.
    /// Recorded rather than acted on: there is no AVPlayer here to hand
    /// drawing to.
    private(set) var nativeSubtitleRenderingRequests: [Bool] = []
    private(set) var nativeSubtitleCaptureRequests: [Bool] = []

    func setNativeSubtitleRendering(_ active: Bool) {
        nativeSubtitleRenderingRequests.append(active)
    }

    func setNativeSubtitleCapture(_ active: Bool) {
        nativeSubtitleCaptureRequests.append(active)
    }

    func setAudioOffset(_ seconds: TimeInterval) {
        guard isAudioOffsetAvailable else { return }
        audioOffsetSeconds = seconds
    }

    func selectSubtitleTrack(id: Int?) {
        subtitleTracks = subtitleTracks.map { $0.selected($0.id == id) }
        onSubtitleTrackChange?(id)
        onSubtitleCuesChange?(Self.cues(forTrack: id))
    }

    private static func cues(forTrack id: Int?) -> [SubtitleCueDisplay] {
        switch id {
        case nil: return []
        case 3: return placedCues
        case 4: return imageCues
        default: return previewCues
        }
    }

    /// One cue spanning the whole runtime, so it is active whatever the clock
    /// says and a test never has to wait for a window to open. No `placement`:
    /// the bottom-centre default is the common case and the one the overlay's
    /// clearance behaviour is about.
    private static let previewCues = [
        SubtitleCueDisplay(
            id: 0, startTime: 0, endTime: .greatestFiniteMagnitude,
            body: .text(UITestFixtureIdentity.plainSubtitleCueText)
        )
    ]

    /// Two text cues the source places itself, for the overlay's
    /// `placementPoint`: one by numpad alignment alone (`\an8`, top centre),
    /// one by an explicit `\pos`. Whole-runtime, as `previewCues`.
    private static let placedCues = [
        SubtitleCueDisplay(
            id: 0, startTime: 0, endTime: .greatestFiniteMagnitude,
            body: .text(UITestFixtureIdentity.alignedSubtitleCueText),
            placement: .init(alignment: 8, position: nil)
        ),
        SubtitleCueDisplay(
            id: 1, startTime: 0, endTime: .greatestFiniteMagnitude,
            body: .text(UITestFixtureIdentity.positionedSubtitleCueText),
            placement: .init(alignment: nil, position: UITestFixtureIdentity.positionedSubtitleCueAnchor)
        )
    ]

    /// One bitmap cue on a 16:9 canvas, taller than the fixture's 2.4:1
    /// picture, as a cropped-video rip authors it: the overlay must map the
    /// canvas width-aligned and centred on the picture (`imageCueFrame`).
    /// Under `anamorphicVideo` the canvas is the coded frame instead, as
    /// AetherEngine reports a DVB or DVD plane, and covers the picture exactly.
    private static let imageCues = [
        SubtitleCueDisplay(
            id: 0, startTime: 0, endTime: .greatestFiniteMagnitude,
            body: .image(
                imageCueBitmap,
                rect: UITestFixtureIdentity.imageSubtitleCueRect,
                canvasSize: UITestConfiguration.scenario == .anamorphicVideo
                    ? UITestFixtureIdentity.anamorphicVideoCodedSize
                    : UITestFixtureIdentity.imageSubtitleCanvasSize
            )
        )
    ]

    /// A plain white bar; only where it lands matters.
    private static let imageCueBitmap: CGImage = {
        let size = CGSize(width: 64, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }()
    /// Reports PiP active, and 3 s later inactive, as when the user returns
    /// from the system's window: there is no AVKit window to stand in for.
    func startPictureInPicture() {
        onPictureInPictureActiveChange?(true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.onPictureInPictureActiveChange?(false)
        }
    }
    func stopPictureInPicture() {
        onPictureInPictureActiveChange?(false)
    }
    func setNowPlayingInfo(title: String, subtitle: String?, artwork: UIImage?) {}

    func makeSurface() -> AnyView {
        AnyView(Color.black)
    }

    // MARK: - Clock

    /// The fixed runtime this fake reports: long enough for a scrub test to have
    /// somewhere to scrub to, and unrelated to the loaded item — nothing here
    /// reads the URL.
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
