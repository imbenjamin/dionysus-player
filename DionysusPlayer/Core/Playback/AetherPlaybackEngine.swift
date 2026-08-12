import Combine
import Foundation
import SwiftUI
import AetherEngine

/// `PlaybackEngine` implemented on top of AetherEngine.
///
/// Adapts AetherEngine's Combine publishers and its `TrackInfo` / `VideoFormat`
/// / `PlaybackState` shapes onto the app's own smaller `PlaybackEngine`
/// protocol so feature code (the player view model and controls overlay)
/// never touches AetherEngine's types directly.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private let engine: AetherEngine
    private var cancellables: Set<AnyCancellable> = []

    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var videoFormatDescription: String?

    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?

    /// Bridges to AetherEngine's own `videoGravity`, which drives whichever
    /// `AVPlayerLayer`/`AVSampleBufferDisplayLayer` is currently bound —
    /// `.resizeAspect` (letterboxed, nothing cropped) for `.fit`,
    /// `.resizeAspectFill` (fills the layer's bounds, cropping any excess)
    /// for `.fill`. Read back from `engine.videoGravity` rather than
    /// mirrored in a stored property, so this can't drift from what's
    /// actually applied to the render layer.
    var zoomMode: VideoZoomMode {
        get { engine.videoGravity == .resizeAspectFill ? .fill : .fit }
        set { engine.videoGravity = newValue == .fill ? .resizeAspectFill : .resizeAspect }
    }

    /// Reads straight off `engine`'s own published/stored properties on
    /// every access rather than mirroring them into stored state — this is
    /// only ever read a couple times a second by `PlaybackStatsOverlay`'s
    /// poll, so there's no reason to duplicate AetherEngine's own bookkeeping
    /// just to save a handful of property reads.
    var stats: PlaybackStats {
        PlaybackStats(
            videoSize: engine.sourceVideoWidth > 0 ? "\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)" : nil,
            frameRate: engine.sourceVideoFrameRate.map { String(format: "%.3g fps", $0) },
            bitrate: engine.sourceVideoBitrate > 0 ? Self.formatBitrate(engine.sourceVideoBitrate) : nil,
            sourceColorFormat: Self.describeColorFormat(engine.sourceVideoFormat, dvProfile: engine.sourceDVProfile),
            displayColorFormat: Self.describeColorFormat(engine.videoFormat, dvProfile: nil),
            videoDecoder: engine.activeVideoDecoder,
            audioDecoder: engine.activeAudioDecoder,
            audioChannels: Self.describeChannels(engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }),
            backend: engine.playbackBackend.rawValue.capitalized,
            // Native-only — see `PlaybackStats.bufferedSeconds`'s doc
            // comment. Confirmed live against a real server/title:
            // AetherEngine's own internal diagnostics (its 30 s memprobe
            // log) showed a software-decode session with every native-path
            // counter (`cacheCount`, `avioFetchedMB`, ...) sitting at a
            // flat 0 while `swFrames` climbed steadily — i.e. genuinely on
            // the software backend, where `bufferedPosition` tracks the
            // playhead by definition rather than any real read-ahead, so
            // diffing it (against either `currentTime` or `sourceTime` —
            // both were tried) can only ever read ~0.
            bufferedSeconds: engine.playbackBackend == .native
                ? max(0, engine.bufferedPosition - engine.sourceTime)
                : nil,
            // `liveTelemetry`'s 1 Hz sampler runs for every session despite
            // the "live" name (started unconditionally alongside the memory
            // probe, not gated on `isLive`) — `cachedBytes` on it is the
            // resident size of the exact same segment cache `bufferedSeconds`
            // above reads the read-ahead frontier from, so it's `nil` in
            // the same native-only case for the same reason.
            bufferedBytes: engine.liveTelemetry?.cachedBytes,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    init() throws {
        self.engine = try AetherEngine()
        observeEngine()
    }

    private func observeEngine() {
        // `$playbackPhase`, not the narrower `$state` this used to watch.
        // AetherEngine can report a mid-playback buffer underrun
        // (`.rebuffering`) or a dropped/retrying source connection
        // (`.stalled(reconnecting:)`) while `state` itself is still
        // `.playing` — see AetherEngine's own `PlaybackPhase.derive(...)` —
        // so `state` alone can't distinguish "actually playing" from
        // "frames stopped, working on it". That gap showed up concretely as
        // the buffering spinner never appearing when a scrub landed
        // somewhere that then needed to rebuffer: `state` stayed `.playing`
        // throughout, so `isBuffering` in `PlayerControlsOverlay` (which
        // only ever saw this bridged value) had nothing to key off. Folding
        // both into `.buffering` here means every AetherEngine surface that
        // isn't genuinely playing/paused/seeking now reaches the host as
        // *something* other than a silently-stuck `.playing`.
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                let bridged: PlaybackState
                switch phase {
                case .idle:              bridged = .idle
                case .loading:           bridged = .loading
                case .playing:           bridged = .playing
                case .paused:            bridged = .paused
                case .seeking:           bridged = .seeking
                case .rebuffering, .stalled: bridged = .buffering
                case .ended:             bridged = .ended
                case .error(let message): bridged = .failed(message)
                }
                MainActor.assumeIsolated {
                    self?.onStateChange?(bridged)
                }
            }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onTimeUpdate?(time, self.engine.duration)
                }
            }
            .store(in: &cancellables)

        engine.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                let description = Self.describe(format)
                MainActor.assumeIsolated {
                    self?.videoFormatDescription = description
                }
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.audioTracks = Self.normalize(tracks, kind: .audio, selectedID: self.selectedAudioTrackID)
                }
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.subtitleTracks = Self.normalize(tracks, kind: .subtitle, selectedID: self.selectedSubtitleTrackID)
                }
            }
            .store(in: &cancellables)
    }

    func load(url: URL) async throws {
        _ = try await engine.load(url: url)
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func togglePlayPause() { engine.togglePlayPause() }
    func stop() { engine.stop() }

    func seek(to time: TimeInterval) async {
        await engine.seek(to: time)
    }

    func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(index: id)
        selectedAudioTrackID = id
        audioTracks = audioTracks.map {
            PlaybackTrack(id: $0.id, kind: $0.kind, displayTitle: $0.displayTitle, isSelected: $0.id == id)
        }
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitleTrackID = id
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
        subtitleTracks = subtitleTracks.map {
            PlaybackTrack(id: $0.id, kind: $0.kind, displayTitle: $0.displayTitle, isSelected: $0.id == id)
        }
    }

    func makeSurface() -> AnyView {
        AnyView(AetherPlayerSurface(engine: engine))
    }

    // MARK: - Bridging

    private static func describe(_ format: VideoFormat) -> String? {
        switch format {
        case .sdr: return nil
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    /// Same cases as `describe(_:)` above, but for `PlaybackStats` rather
    /// than the scrubber's format badge: always returns a label (including
    /// "SDR", where `describe(_:)` returns `nil` so the badge just doesn't
    /// show), and folds in the Dolby Vision profile number when known.
    private static func describeColorFormat(_ format: VideoFormat, dvProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return dvProfile.map { "Dolby Vision (Profile \($0))" } ?? "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    private static func formatBitrate(_ bitsPerSecond: Int64) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// `TrackInfo.channels` is a plain count (2/6/8/...) meant, per its own
    /// doc comment, "for Stats-for-Nerds" — this is that label. `isAtmos`
    /// takes priority over the raw count, same as AetherEngine's own doc
    /// comment on that field recommends ("surface 'Atmos' instead of the
    /// bed channel count, typically 5.1").
    private static func describeChannels(_ track: TrackInfo?) -> String? {
        guard let track, track.channels > 0 else { return nil }
        if track.isAtmos { return "Atmos" }
        switch track.channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(track.channels)ch"
        }
    }

    private static func normalize(_ tracks: [TrackInfo], kind: PlaybackTrack.Kind, selectedID: Int?) -> [PlaybackTrack] {
        tracks.map { track in
            PlaybackTrack(
                id: track.id,
                kind: kind,
                displayTitle: displayTitle(for: track),
                isSelected: track.id == selectedID
            )
        }
    }

    private static func displayTitle(for track: TrackInfo) -> String {
        if !track.name.isEmpty { return track.name }
        if let language = track.language, !language.isEmpty { return language }
        return "Track \(track.id)"
    }
}
