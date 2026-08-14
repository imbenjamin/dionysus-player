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
    /// Set once per `load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`
    /// call, read by the `$audioTracks` subscription below every time
    /// AetherEngine republishes the list — see that parameter's doc comment
    /// on the protocol for why this exists.
    private var knownAtmosAudioTrackIndices: Set<Int> = []

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
                    self.audioTracks = Self.normalize(
                        tracks, kind: .audio, selectedID: self.selectedAudioTrackID,
                        knownAtmosAudioTrackIndices: self.knownAtmosAudioTrackIndices
                    )
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

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
        self.knownAtmosAudioTrackIndices = knownAtmosAudioTrackIndices
        let options = LoadOptions(externalSubtitles: externalSubtitles.map(Self.makeExternalSubtitleTrack))
        _ = try await engine.load(url: url, options: options)
        applyForcedSubtitleSelection()
    }

    /// A "forced" subtitle track exists specifically to caption content the audio track doesn't
    /// already carry in the viewer's language (foreign-language dialogue, on-screen signs) — real
    /// players activate one on load regardless of the viewer's general subtitles-on/off preference,
    /// rather than waiting for an explicit pick. Runs once, right after a fresh `load()`; a later
    /// user pick (`selectSubtitleTrack(id:)`) is untouched by this — there's nothing left for it to
    /// do once the host (this call) has already made an explicit choice, same as any other
    /// `hostExplicitSubtitleAction`.
    ///
    /// Source is `TrackInfo.isForced` — the container's own FORCED disposition — covering embedded
    /// *and* declared-external tracks alike (both are seated in `engine.subtitleTracks` by the time
    /// `engine.load()` returns; see `registerDeclaredExternalSubtitles`'s doc comment). No title/name
    /// text-matching, same principle as `knownAtmosAudioTrackIndices` above.
    ///
    /// Selection when more than one forced track exists (rare — most sources carry at most one, but
    /// nothing stops a multi-language disc/rip from carrying several): prefer whichever forced
    /// track's language matches the audio track AetherEngine resolved as active for this load,
    /// keeping the first match in container order if more than one still ties; fall back to the
    /// first forced track in container order if none match (or the active audio track's language is
    /// unknown). Confirmed live (2026-08-14) against a real "Captain Phillips" source carrying an
    /// English Forced track alongside full subtitle tracks.
    private func applyForcedSubtitleSelection() {
        let forcedTracks = engine.subtitleTracks.filter(\.isForced)
        guard !forcedTracks.isEmpty else { return }
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        let best = forcedTracks.first { Self.languageMatches($0.language, audioLanguage) } ?? forcedTracks[0]
        selectSubtitleTrack(id: best.id)
    }

    /// Case-insensitive, trimmed equality — deliberately simpler than AetherEngine's own internal
    /// language matcher (which also folds ISO 639-1/639-2 B/T variants and English names together,
    /// e.g. "en"/"eng"/"english"), since that helper isn't exposed outside the package. A non-issue
    /// in practice: the forced subtitle track and the audio track it's compared against come from the
    /// same container, which tags both with the same language-code convention (almost always plain
    /// ISO 639-2), so an exact match after trimming/casing is enough. `nil` on either side never
    /// matches, same as AetherEngine's own rule.
    private static func languageMatches(_ trackLanguage: String?, _ other: String?) -> Bool {
        guard let trackLanguage = trackLanguage?.trimmingCharacters(in: .whitespaces), !trackLanguage.isEmpty,
              let other = other?.trimmingCharacters(in: .whitespaces), !other.isEmpty else { return false }
        return trackLanguage.caseInsensitiveCompare(other) == .orderedSame
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

    private static func makeExternalSubtitleTrack(_ source: ExternalSubtitleSource) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(
            url: source.url,
            name: source.name,
            language: source.language,
            isForced: source.isForced,
            isHearingImpaired: source.isHearingImpaired,
            isDefault: source.isDefault,
            formatHint: source.formatHint
        )
    }

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

    private static func normalize(
        _ tracks: [TrackInfo], kind: PlaybackTrack.Kind, selectedID: Int?,
        knownAtmosAudioTrackIndices: Set<Int> = []
    ) -> [PlaybackTrack] {
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
                metadata: metadataLabel(
                    for: track, kind: kind, providedName: providedName,
                    knownAtmosAudioTrackIndices: knownAtmosAudioTrackIndices
                ),
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
    ///
    /// Audio tracks additionally get the format (e.g. "DD+"), an "Atmos"
    /// flag when applicable, and channel layout (e.g. "5.1") right after
    /// the language, ahead of the boolean flags — see
    /// `audioFormatLabel`/`channelsLabel`. None of the three apply to
    /// subtitle tracks (`channels`/codec-as-audio-format are meaningless
    /// there), hence `kind` gating them.
    ///
    /// "Atmos" is deliberately its own flag, additive to `audioFormatLabel`
    /// rather than replacing it (that was the original, wrong shape here —
    /// see that function's doc comment): a Dolby Digital Plus/Atmos track
    /// is still a DD+ track first and foremost, same as the file's own
    /// embedded title reads "Dolby TrueHD Atmos"/"Dolby Digital Plus
    /// Atmos" — format *and* Atmos together, never just one. Its source is
    /// `track.isAtmos` OR `knownAtmosAudioTrackIndices` (Jellyfin's own
    /// `MediaStream.audioSpatialFormat`, forwarded at load time) — see the
    /// `PlaybackEngine.load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`
    /// doc comment for why both are needed rather than just the former.
    private static func metadataLabel(
        for track: TrackInfo, kind: PlaybackTrack.Kind, providedName: String?,
        knownAtmosAudioTrackIndices: Set<Int>
    ) -> String? {
        var flags: [String] = []
        if providedName != nil, let language = track.language, let friendly = friendlyLanguageName(language) {
            flags.append(friendly)
        }
        if kind == .audio {
            if let format = audioFormatLabel(for: track) { flags.append(format) }
            if track.isAtmos || knownAtmosAudioTrackIndices.contains(track.id) { flags.append("Atmos") }
            if let channels = channelsLabel(for: track) { flags.append(channels) }
        }
        if track.isDefault { flags.append(String(localized: "Default")) }
        if track.isForced { flags.append(String(localized: "Forced")) }
        if track.isHearingImpaired { flags.append(String(localized: "Hearing Impaired")) }
        if track.isCommentary { flags.append(String(localized: "Commentary")) }
        if track.isExternal { flags.append(String(localized: "External")) }
        return flags.isEmpty ? nil : flags.joined(separator: " \u{00B7} ")
    }

    /// The metadata line's audio-format entry — the underlying codec
    /// family, same shorthand `MediaItem.metadataBadges` uses for the
    /// Details tab ("DD"/"DD+"/"Dolby TrueHD"/"DTS"), kept consistent
    /// across the app rather than inventing a second vocabulary here.
    /// Unlike that badge (server-side `MediaStream.profile`, which can
    /// tell DTS-HD apart from core DTS), `TrackInfo.codec` is just the bare
    /// libavcodec name with no profile info, so every DTS-family track
    /// reads as plain "DTS" here — an accepted simplification, not a bug,
    /// for this data source. `nil` for a codec with no established
    /// shorthand (rare in practice) rather than showing a raw, none-too-
    /// friendly libavcodec name verbatim.
    ///
    /// Deliberately does NOT special-case `track.isAtmos` — `metadataLabel`
    /// appends "Atmos" as its own separate flag instead. A first version of
    /// this returned "Dolby Atmos" here in place of the codec's own format
    /// (e.g. hiding "DD+"), which silently lost real information: a Dolby
    /// Digital Plus/Atmos track and a Dolby TrueHD/Atmos track both
    /// legitimately carry Atmos, but they're not interchangeable — TrueHD's
    /// lossless core is the higher-quality carrier of the two — and
    /// collapsing both to a bare "Dolby Atmos" made them indistinguishable
    /// (found live, 2026-08-14, on a Saving Private Ryan source with both).
    ///
    /// `"dca"` (not just `"dts"`) matches DTS: `Demuxer.trackInfo(from:)`
    /// sets `codec` from `avcodec_find_decoder(...).pointee.name` — the
    /// FFmpeg *decoder's* own registered name, not the codec's canonical
    /// short name — and FFmpeg's DTS decoder has historically been
    /// registered as `"dca"` (`ffmpeg -codecs` shows `dts ... (decoders:
    /// dca) (encoders: dca)`); confirmed live (2026-08-14) that every DTS
    /// track's `codec` actually reads `"dca"`, not `"dts"`. `"dts"` stays
    /// as a fallback for the rarer case `trackInfo(from:)` falls back to
    /// the codec-descriptor name (no decoder built).
    private static func audioFormatLabel(for track: TrackInfo) -> String? {
        switch track.codec.lowercased() {
        case "ac3": return "DD"
        case "eac3": return "DD+"
        case "truehd": return "Dolby TrueHD"
        case "dts", "dca": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default:
            return track.codec.hasPrefix("pcm") ? "PCM" : nil
        }
    }

    /// The metadata line's channel-layout entry — friendlier labels
    /// ("Mono"/"Stereo") than `describeChannels` above uses for Stats-for-
    /// Nerds ("1.0"/"2.0"), which is a denser diagnostics readout rather
    /// than a picker row a user reads at a glance. Deliberately does NOT
    /// collapse to "Atmos" for an Atmos track the way `describeChannels`
    /// does — `audioFormatLabel` already surfaces that, and the bed channel
    /// count (typically 5.1) is still useful alongside it here.
    private static func channelsLabel(for track: TrackInfo) -> String? {
        guard track.channels > 0 else { return nil }
        switch track.channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(track.channels)ch"
        }
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
