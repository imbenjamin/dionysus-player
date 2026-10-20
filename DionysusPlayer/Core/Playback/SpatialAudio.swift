import Foundation

/// A speaker layout object audio can be rendered into, named as AetherEngine's
/// `SpatialSpeakerLayout` is ("7.1.4": formatted data, never localized).
/// `AetherPlaybackEngine` maps one to the other by raw value, so feature code
/// never sees the engine's type.
enum SpeakerLayout: String, CaseIterable, Codable, Sendable {
    case l512 = "5.1.2"
    case l514 = "5.1.4"
    case l712 = "7.1.2"
    case l714 = "7.1.4"
    case l916 = "9.1.6"

    private var isDefault: Bool { self == SpatialAudioFormat.defaultLayout }

    /// A layout picker's option, the default marked as such on both
    /// platforms (Benjamin, 2026-10-20).
    var optionLabel: String {
        isDefault ? String(localized: "\(rawValue) (Default)") : rawValue
    }

    /// What VoiceOver reads for an option: the bare numbers say nothing of
    /// what they count.
    var accessibilityLabel: String {
        isDefault ? String(localized: "\(rawValue) speakers (Default)") : String(localized: "\(rawValue) speakers")
    }
}

/// The two track formats that lose their heights on today's path: Apple
/// platforms can't bitstream TrueHD or DTS-HD, so the engine decodes them and
/// re-encodes to Dolby Digital Plus. Rendered as Spatial Audio they keep them,
/// at the cost of a lossy encode (Benjamin, 2026-10-19: one toggle each).
enum SpatialAudioFormat: CaseIterable, Sendable {
    /// TrueHD carrying Dolby Atmos. E-AC-3 JOC isn't one: it's stream-copied
    /// with its objects already.
    case dolbyAtmos
    case dtsX

    /// The layouts the engine renders this format into. DTS:X's four heights
    /// route one to one, so only into 7.1.4 and 9.1.6.
    var layouts: [SpeakerLayout] {
        switch self {
        case .dolbyAtmos: return SpeakerLayout.allCases
        case .dtsX: return [.l714, .l916]
        }
    }

    /// The commonest Atmos home layout, one DTS:X can use, and what headphone
    /// Spatial Audio renders from.
    static let defaultLayout = SpeakerLayout.l714
}

/// The viewer's two Spatial Audio choices: per device, both off by default.
struct SpatialAudioSettings: Equatable, Sendable {
    var atmosEnabled = false
    var atmosLayout = SpatialAudioFormat.defaultLayout
    var dtsXEnabled = false
    var dtsXLayout = SpatialAudioFormat.defaultLayout

    /// The layout to render `format` into, or nil while it's off.
    func layout(for format: SpatialAudioFormat) -> SpeakerLayout? {
        switch format {
        case .dolbyAtmos: return atmosEnabled ? atmosLayout : nil
        case .dtsX: return dtsXEnabled ? dtsXLayout : nil
        }
    }
}

/// What a playback session renders object audio as: AetherEngine's
/// `objectAudioRendering`, one value for the whole session and for both
/// formats, which is why the player predicts the track before it loads.
enum SpatialAudioRendering: Equatable, Sendable {
    case off
    case layout(SpeakerLayout)
}

/// The pure rules behind the two settings, kept apart from the player so they
/// can be tested over track lists.
enum SpatialAudioRules {
    /// Which format `stream` is, from Jellyfin's own labels:
    /// `AudioSpatialFormat` with the codec, since E-AC-3 JOC is labelled
    /// `DolbyAtmos` too.
    static func format(of stream: MediaStream) -> SpatialAudioFormat? {
        guard stream.type == "Audio" else { return nil }
        let codec = stream.codec?.lowercased()
        switch (codec, stream.audioSpatialFormat) {
        case ("truehd", "DolbyAtmos"): return .dolbyAtmos
        case ("dts", "DTSX"): return .dtsX
        default: return nil
        }
    }

    /// The rendering a session playing `stream` should load with.
    static func rendering(for stream: MediaStream?, settings: SpatialAudioSettings) -> SpatialAudioRendering {
        guard let stream, let format = format(of: stream), let layout = settings.layout(for: format) else { return .off }
        return .layout(layout)
    }

    /// The audio track a session will most likely play, before it loads: the
    /// title's remembered choice; else the engine's own pick, which is the
    /// default track (or the first), swapped for a TrueHD Atmos or DTS:X track
    /// of the same language when rendering would be on for it (AetherEngine
    /// prefers one then, never across a language and never a commentary).
    /// A wrong guess costs one rebuild after load, so this needn't be perfect.
    static func predictedAudioStream(
        in streams: [MediaStream], rememberedTrackID: Int?, settings: SpatialAudioSettings
    ) -> MediaStream? {
        let audio = streams.filter { $0.type == "Audio" }
        if let rememberedTrackID, let remembered = audio.first(where: { $0.index == rememberedTrackID }) {
            return remembered
        }
        guard let fallback = audio.first(where: { $0.isDefault == true }) ?? audio.first else { return nil }
        let preferred = audio.first { candidate in
            guard let format = format(of: candidate), settings.layout(for: format) != nil else { return false }
            let isCommentary = (candidate.title ?? candidate.displayTitle ?? "").localizedCaseInsensitiveContains("commentary")
            return !isCommentary && candidate.language == fallback.language
        }
        return preferred ?? fallback
    }
}
