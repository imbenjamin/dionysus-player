import Foundation

/// Both this default and `ProfileView`'s own `@AppStorage` default must be
/// declared identically by hand — nothing enforces they stay in sync (same
/// discipline as `DownloadPreferencesStore`'s documented gotcha).
let streamDecisionModeStorageKey = "streamDecisionModePreference"
let streamingMaxBitrateStorageKey = "streamingMaxBitratePreference"

/// Direct Play Always (default, unchanged app behavior — no `/PlaybackInfo`
/// negotiation, always a `Static=true` stream URL) vs. Allow Transcoding
/// (sends a real `DeviceProfile`, per `DeviceProfileBuilder`, and lets the
/// server fall back to an HLS transcode when it decides direct play isn't
/// possible).
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

/// Caps `DeviceProfile.maxStreamingBitrate` when `StreamDecisionMode ==
/// .allowTranscoding` — meaningless in Direct Play Always mode, where no
/// `DeviceProfile` is ever sent. Named for what it actually gates, not for
/// *when* it happens to matter: this is a ceiling on the delivered
/// stream's bitrate full stop, not just a cap applied once a transcode is
/// already happening for some other reason — confirmed live (2026-08-28) a
/// source whose own bitrate exceeds the chosen cap gets forced to
/// transcode specifically *because of* this setting, even though it's
/// otherwise perfectly direct-playable (codec/container/tag all fine).
/// Direct play can't be throttled — the file goes out byte-for-byte at its
/// original bitrate or not at all — so this is the only lever that can
/// turn "would have direct played" into "must transcode."
///
/// The visible label ("40 Mbps") and its VoiceOver counterpart ("40
/// megabits per second") deliberately differ — "Mbps" read letter-by-letter
/// ("M B P S") is how VoiceOver reads it by default, same problem
/// `DownloadBitratePreset.accessibilityDisplayName(in:)`
/// (`DownloadTypes.swift`) already solves for the downloads quality picker;
/// this repeats that pattern rather than introducing a new one.
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

    /// `nil` means "no user-imposed cap" — `DeviceProfileBuilder.build(_:)`
    /// is responsible for turning that into whatever concrete value
    /// actually reaches the server (NOT simply omitting the field: see
    /// its own doc comment on why absence doesn't mean "unlimited" to
    /// Jellyfin in practice). This enum only expresses the user's intent.
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

/// Streaming-mode/bitrate-cap settings for live playback. Local to the
/// device only, like `DownloadPreferencesStore`/`NextUpPreferenceStore`:
/// plain `UserDefaults`, not sensitive, never round-tripped through the
/// server — and, like `DownloadPreferencesStore`, device-wide rather than
/// scoped per Jellyfin user, since which streaming strategy/bandwidth cap
/// to use is a property of the device/network, not of whoever's currently
/// signed in.
///
/// Read-only and injectable, same shape as `DownloadPreferencesStore` —
/// `ProfileView`'s own `@AppStorage` pickers are the only writer, using the
/// exact same keys, so non-view code (`PlayerViewModel`) can read the live
/// setting without a SwiftUI environment of their own.
struct StreamPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var decisionMode: StreamDecisionMode {
        defaults.string(forKey: streamDecisionModeStorageKey).flatMap(StreamDecisionMode.init(rawValue:)) ?? .directPlayAlways
    }

    var streamingMaxBitrate: StreamingMaxBitrate {
        defaults.string(forKey: streamingMaxBitrateStorageKey).flatMap(StreamingMaxBitrate.init(rawValue:)) ?? .unlimited
    }
}
