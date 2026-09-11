import Foundation

/// This default and `ProfileView`'s `@AppStorage` default are declared by hand
/// in both places, with nothing enforcing they stay in sync.
let streamDecisionModeStorageKey = "streamDecisionModePreference"
let streamingMaxBitrateStorageKey = "streamingMaxBitratePreference"

/// Allow Transcoding, the default, sends a real `DeviceProfile` and lets the
/// server fall back to an HLS transcode when direct play isn't possible. Direct
/// Play Always skips `/PlaybackInfo` negotiation for a `Static=true` stream URL
/// — more fragile, and kept only for anyone who wants to force it.
///
/// Allow Transcoding could only become the default once the transcode target
/// moved to fMP4; the earlier MPEG-TS, H.264-only target's HEVC black-screen bug
/// (see `DeviceProfile.swift`) made Direct Play Always the safer choice.
enum StreamDecisionMode: String, Codable, CaseIterable, Identifiable {
    case directPlayAlways
    case allowTranscoding

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .directPlayAlways: return String(localized: "Direct Play Always")
        case .allowTranscoding: return String(localized: "Allow Transcoding")
        }
    }
}

/// Caps `DeviceProfile.maxStreamingBitrate` in Allow Transcoding mode, and is
/// meaningless in Direct Play Always, where no profile is sent.
///
/// A ceiling on the delivered stream's bitrate outright, not a cap applied once
/// a transcode is happening for some other reason: an otherwise direct-playable
/// source whose bitrate exceeds this is forced to transcode because of it.
/// Direct play can't be throttled — the file goes out at its original bitrate or
/// not at all — so this is the only lever that turns "would have direct played"
/// into "must transcode".
///
/// The visible label and its VoiceOver counterpart differ because VoiceOver
/// reads "Mbps" letter by letter.
enum StreamingMaxBitrate: String, Codable, CaseIterable, Identifiable {
    case unlimited
    case mbps40
    case mbps20
    case mbps10
    case mbps4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unlimited: return String(localized: "Unlimited")
        case .mbps40: return String(localized: "40 Mbps")
        case .mbps20: return String(localized: "20 Mbps")
        case .mbps10: return String(localized: "10 Mbps")
        case .mbps4: return String(localized: "4 Mbps")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .unlimited: return String(localized: "Unlimited")
        case .mbps40: return String(localized: "40 megabits per second")
        case .mbps20: return String(localized: "20 megabits per second")
        case .mbps10: return String(localized: "10 megabits per second")
        case .mbps4: return String(localized: "4 megabits per second")
        }
    }

    /// `nil` means no user-imposed cap. This enum expresses intent only;
    /// `DeviceProfileBuilder.build(_:)` turns it into the value that reaches the
    /// server, which is never an omitted field — absence doesn't mean unlimited
    /// to Jellyfin.
    var bitsPerSecond: Int? {
        switch self {
        case .unlimited: return nil
        case .mbps40: return 40_000_000
        case .mbps20: return 20_000_000
        case .mbps10: return 10_000_000
        case .mbps4: return 4_000_000
        }
    }
}

/// Streaming-mode and bitrate-cap settings for live playback. Device-local
/// `UserDefaults`, never round-tripped through the server, and device-wide
/// rather than per Jellyfin user: which streaming strategy and bandwidth cap to
/// use is a property of the device and network.
///
/// Read-only and injectable. `ProfileView`'s `@AppStorage` pickers are the only
/// writer, using the same keys, so non-view code can read the live setting with
/// no SwiftUI environment.
struct StreamPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var decisionMode: StreamDecisionMode {
        defaults.string(forKey: streamDecisionModeStorageKey).flatMap(StreamDecisionMode.init(rawValue:)) ?? .allowTranscoding
    }

    var streamingMaxBitrate: StreamingMaxBitrate {
        defaults.string(forKey: streamingMaxBitrateStorageKey).flatMap(StreamingMaxBitrate.init(rawValue:)) ?? .unlimited
    }
}
