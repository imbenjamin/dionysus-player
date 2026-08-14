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
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)?
    var onSourceTimeUpdate: ((TimeInterval) -> Void)?

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var videoFormatDescription: String?

    /// Read straight off `engine`'s own stored properties, same reasoning as
    /// `stats` above — they're set once per source and rarely re-read.
    var videoNaturalSize: CGSize? {
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
    }

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

        // Separate from `clock.$currentTime` above on purpose — subtitle
        // cues are stamped in source PTS, which can diverge from the item/
        // AVPlayer-axis clock across producer restarts (see
        // `PlaybackEngine.onSourceTimeUpdate`'s doc comment).
        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                MainActor.assumeIsolated {
                    self?.onSourceTimeUpdate?(sourceTime)
                }
            }
            .store(in: &cancellables)

        // AetherEngine draws nothing itself ("the engine emits SubtitleCue;
        // your UI paints them") — this is the only place cues cross into
        // the app, normalized to `SubtitleCueDisplay` so the rest of the
        // app never touches AetherEngine's `SubtitleCue`/`SubtitleTextRun`/
        // `SubtitleImage` directly, same as `audioTracks`/`subtitleTracks`
        // above do for `TrackInfo`.
        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                MainActor.assumeIsolated {
                    self?.onSubtitleCuesChange?(cues.map(Self.normalize))
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

        // `selectedAudioTrackID`/`selectedSubtitleTrackID` used to be written
        // *only* from `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` — an
        // explicit user pick — which left both `nil` (so nothing showed a
        // checkmark) for the entire stretch between load and the first
        // manual selection, even though AetherEngine had already resolved
        // and was actively playing a default track the whole time. These two
        // subscriptions pick up that resolved default (and any other
        // engine-internal change to the active track, e.g. after the
        // `reloadWithAudioOverride` a track switch triggers) directly from
        // AetherEngine's own published `activeAudioTrackIndex`/
        // `activeSubtitleTrackIndex`, independent of firing order against
        // the `$audioTracks`/`$subtitleTracks` subscriptions above — whichever
        // of the two arrives second is what actually paints the checkmark,
        // and either order lands on the same result.
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.selectedAudioTrackID = index
                    self.audioTracks = self.audioTracks.map { $0.selected($0.id == index) }
                }
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.selectedSubtitleTrackID = index
                    self.subtitleTracks = self.subtitleTracks.map { $0.selected($0.id == index) }
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
        audioTracks = audioTracks.map { $0.selected($0.id == id) }
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitleTrackID = id
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
        subtitleTracks = subtitleTracks.map { $0.selected($0.id == id) }
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
            // Computed once and threaded through both `title(for:)` and
            // `metadataLabel(for:)` — the latter needs to know whether the
            // former is *about* to show the provided name rather than the
            // language, so it can put the language back on the metadata
            // line instead of losing it entirely (see that doc comment).
            let providedName = descriptiveName(track)
            return PlaybackTrack(
                id: track.id,
                kind: kind,
                title: title(for: track, providedName: providedName),
                metadata: metadataLabel(for: track, providedName: providedName),
                isSelected: track.id == selectedID
            )
        }
    }

    /// The row's main line: `providedName` (`track.name`, when it reads as
    /// a genuinely descriptive title, e.g. "Director's Commentary") when
    /// there is one, otherwise a user-friendly language name built from
    /// `track.language`. Muxers commonly set `name` to a bare, none-too-
    /// friendly echo of the language field ("ENG", "ENG (srt)") that adds
    /// no information beyond what `metadataLabel(for:)` and the language
    /// itself already cover — `descriptiveName(_:)` filters those out so
    /// this falls through to the friendly language name instead of showing
    /// the raw label verbatim.
    private static func title(for track: TrackInfo, providedName: String?) -> String {
        if let providedName { return providedName }
        if let language = track.language, let friendly = friendlyLanguageName(language) { return friendly }
        if !track.name.isEmpty { return track.name }
        return String(localized: "Track \(track.id)")
    }

    /// `nil` when `track.name` is empty, or — once a trailing "(...)"
    /// parenthetical is stripped (the "(srt)" in "ENG (srt)") — is just the
    /// raw language code or its own friendly name wearing different
    /// capitalization ("ENG"/"eng"/"English" for an `.language` of "eng").
    /// Non-nil (and returned verbatim) only for a name that's actually
    /// carrying information beyond the language, like "Director's
    /// Commentary" or "Director's Commentary with Brad Pitt, Edward Norton
    /// & Helena Bonham Carter".
    private static func descriptiveName(_ track: TrackInfo) -> String? {
        guard !track.name.isEmpty else { return nil }
        guard let language = track.language, !language.isEmpty else { return track.name }
        let stripped = track.name
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped.caseInsensitiveCompare(language) == .orderedSame { return nil }
        if let friendly = friendlyLanguageName(language), stripped.caseInsensitiveCompare(friendly) == .orderedSame {
            return nil
        }
        return track.name
    }

    private static func friendlyLanguageName(_ languageCode: String) -> String? {
        Locale.current.localizedString(forIdentifier: languageCode)
    }

    /// The row's secondary line: whichever flags apply, in this fixed
    /// order, space-dot-joined — `nil` when none do, so `selectionRow`
    /// shows a single-line row rather than an empty second line.
    ///
    /// When `providedName` is non-nil, `title(for:providedName:)` is about
    /// to show it instead of the language — the language would otherwise
    /// not appear anywhere on the row at all, so it leads the flag list
    /// here instead (e.g. "English · Commentary" under "Director's
    /// Commentary").
    private static func metadataLabel(for track: TrackInfo, providedName: String?) -> String? {
        var flags: [String] = []
        if providedName != nil, let language = track.language, let friendly = friendlyLanguageName(language) {
            flags.append(friendly)
        }
        if track.isDefault { flags.append(String(localized: "Default")) }
        if track.isForced { flags.append(String(localized: "Forced")) }
        if track.isHearingImpaired { flags.append(String(localized: "Hearing Impaired")) }
        if track.isCommentary { flags.append(String(localized: "Commentary")) }
        if track.isExternal { flags.append(String(localized: "External")) }
        return flags.isEmpty ? nil : flags.joined(separator: " \u{00B7} ")
    }

    private static func normalize(_ cue: SubtitleCue) -> SubtitleCueDisplay {
        SubtitleCueDisplay(
            id: cue.id,
            startTime: cue.startTime,
            endTime: cue.endTime,
            body: normalize(cue.body),
            placement: cue.placement.map { SubtitleCueDisplay.Placement(alignment: $0.alignment, position: $0.position) }
        )
    }

    private static func normalize(_ body: SubtitleCue.Body) -> SubtitleCueDisplay.Body {
        switch body {
        case .text(let string):
            return .text(string)
        case .richText(let runs):
            return .richText(runs.map(normalize))
        case .image(let image):
            return .image(image.cgImage, rect: image.position, canvasSize: image.canvasSize)
        }
    }

    private static func normalize(_ run: SubtitleTextRun) -> SubtitleCueDisplay.Run {
        SubtitleCueDisplay.Run(
            text: run.text,
            color: run.color.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) },
            isBold: run.isBold,
            isItalic: run.isItalic,
            isUnderlined: run.isUnderlined,
            isStruckThrough: run.isStruckThrough
        )
    }
}
