import Foundation

/// Resolution tier for an offline download's transcode target — caps
/// `MaxWidth`/`MaxHeight` sent to Jellyfin's transcoder
/// (`JellyfinAPIClient.downloadStreamURL`). Never allowed to exceed the
/// source's own resolution — see `DownloadTranscodeCalculator.target`.
enum DownloadResolution: String, Codable, CaseIterable, Identifiable {
    case uhd4K
    case hd1080p
    case sd480p

    var id: String { rawValue }

    var maxWidth: Int {
        switch self {
        case .uhd4K: return 3840
        case .hd1080p: return 1920
        case .sd480p: return 854
        }
    }

    var maxHeight: Int {
        switch self {
        case .uhd4K: return 2160
        case .hd1080p: return 1080
        case .sd480p: return 480
        }
    }

    var displayName: String {
        switch self {
        case .uhd4K: return String(localized: "4K UHD")
        case .hd1080p: return String(localized: "1080p HD")
        case .sd480p: return String(localized: "480p SD")
        }
    }

    /// Video bitrate in bits/sec for this tier at the given preset — the
    /// bitrate ladder from the offline-downloads plan: 4K 20/12/6 Mbps,
    /// 1080p 6/3/1.5 Mbps, 480p 2/1.2/0.6 Mbps (High/Normal/Data Saver).
    func videoBitrate(preset: DownloadBitratePreset) -> Int {
        switch (self, preset) {
        case (.uhd4K, .high):      return 20_000_000
        case (.uhd4K, .normal):    return 12_000_000
        case (.uhd4K, .dataSaver): return 6_000_000
        case (.hd1080p, .high):      return 6_000_000
        case (.hd1080p, .normal):    return 3_000_000
        case (.hd1080p, .dataSaver): return 1_500_000
        case (.sd480p, .high):      return 2_000_000
        case (.sd480p, .normal):    return 1_200_000
        case (.sd480p, .dataSaver): return 600_000
        }
    }
}

/// Quality preset within a `DownloadResolution` tier. Audio is always
/// AAC-LC stereo for v1 (deliberate simplification — surround passthrough
/// is a later follow-up), so only its bitrate varies by preset, and does so
/// independently of resolution — unlike video bitrate, which is a function
/// of both (see `DownloadResolution.videoBitrate(preset:)`).
enum DownloadBitratePreset: String, Codable, CaseIterable, Identifiable {
    case high
    case normal
    case dataSaver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return String(localized: "High")
        case .normal: return String(localized: "Normal")
        case .dataSaver: return String(localized: "Data Saver")
        }
    }

    /// Audio bitrate in bits/sec — 192/160/96 kbps for High/Normal/Data Saver.
    var audioBitrate: Int {
        switch self {
        case .high: return 192_000
        case .normal: return 160_000
        case .dataSaver: return 96_000
        }
    }

    /// e.g. "High (6 Mbps)" — the actual video bitrate for this preset
    /// depends on which `DownloadResolution` tier it's paired with (see the
    /// bitrate ladder table), so this takes that tier as a parameter rather
    /// than being a fixed label like `displayName`. Used by `ProfileView`'s
    /// quality picker so each row shows the real number, not just a vague
    /// "High"/"Normal"/"Data Saver" label.
    func displayName(in resolution: DownloadResolution) -> String {
        let mbps = Double(resolution.videoBitrate(preset: self)) / 1_000_000
        let mbpsText = mbps == mbps.rounded() ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
        return "\(displayName) (\(mbpsText) Mbps)"
    }
}

/// The concrete transcode parameters `JellyfinAPIClient.downloadStreamURL`
/// sends to Jellyfin for one download, after applying the "never upscale/
/// never inflate past the source" capping rule — see
/// `DownloadTranscodeCalculator.target`.
struct DownloadTranscodeTarget: Equatable {
    var maxWidth: Int
    var maxHeight: Int
    /// Bits/sec.
    var videoBitrate: Int
    /// Jellyfin's `VideoProfile` param — `"main10"` for an HDR source (so
    /// the transcoder actually preserves the extra bit depth rather than
    /// crushing it to 8-bit `"main"`), `"main"` otherwise.
    var videoProfile: String
}

/// Pure resolution/bitrate-capping logic, split out from
/// `JellyfinAPIClient.downloadStreamURL` so it's unit-testable without a
/// mock network layer (see the offline-downloads plan's Testing section).
enum DownloadTranscodeCalculator {
    /// Resolution tiers cap `MaxWidth`/`MaxHeight` and are never allowed to
    /// exceed the source's own resolution (`effective = min(tierMax,
    /// sourceDimension)`); video bitrate is likewise capped to the source's
    /// own bitrate when that's lower than the tier target, so a low-bitrate
    /// source is never artificially inflated. `sourceWidth`/`sourceHeight`/
    /// `sourceBitrate` of `nil` (metadata Jellyfin didn't report) skips that
    /// particular cap rather than failing — the tier's own max is used as-is.
    static func target(
        resolution: DownloadResolution,
        preset: DownloadBitratePreset,
        isSourceHDR: Bool,
        sourceWidth: Int?,
        sourceHeight: Int?,
        sourceBitrate: Int?
    ) -> DownloadTranscodeTarget {
        DownloadTranscodeTarget(
            maxWidth: min(resolution.maxWidth, sourceWidth ?? resolution.maxWidth),
            maxHeight: min(resolution.maxHeight, sourceHeight ?? resolution.maxHeight),
            videoBitrate: min(resolution.videoBitrate(preset: preset), sourceBitrate ?? resolution.videoBitrate(preset: preset)),
            videoProfile: isSourceHDR ? "main10" : "main"
        )
    }
}
