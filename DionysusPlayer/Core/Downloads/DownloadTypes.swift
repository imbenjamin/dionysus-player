import Foundation

/// Resolution tier for a download's transcode target, capping the
/// `MaxWidth`/`MaxHeight` sent to Jellyfin's transcoder and never exceeding the
/// source's own resolution (see `DownloadTranscodeCalculator.target`).
///
/// `DOWNLOADS.md` covers the ladder's shape; `videoBitrate(preset:)` has the
/// short version.
enum DownloadResolution: String, Codable, CaseIterable, Identifiable {
    case uhd4K
    case hd1080p
    case hd720p
    case sd480p

    var id: String { rawValue }

    var maxWidth: Int {
        switch self {
        case .uhd4K: return 3840
        case .hd1080p: return 1920
        case .hd720p: return 1280
        case .sd480p: return 854
        }
    }

    var maxHeight: Int {
        switch self {
        case .uhd4K: return 2160
        case .hd1080p: return 1080
        case .hd720p: return 720
        case .sd480p: return 480
        }
    }

    var displayName: String {
        switch self {
        case .uhd4K: return String(localized: "4K UHD")
        case .hd1080p: return String(localized: "1080p Full HD")
        case .hd720p: return String(localized: "720p HD")
        case .sd480p: return String(localized: "480p SD")
        }
    }

    /// Video bitrate in bits/sec for this tier at the given preset.
    ///
    /// The ladder is constant bits-per-pixel-per-frame rather than a set of
    /// round numbers: each preset has a bpp target (High 0.095, Normal 0.062,
    /// Data Saver 0.032, at 24fps) applied across every tier, so a rung's
    /// quality means the same thing at any resolution. **Changing a number here
    /// means re-checking it against its preset's bpp**, or the tiers stop being
    /// comparable.
    ///
    /// Smaller resolutions carry a higher bpp target (480p ×1.15, 720p ×1.08,
    /// 4K ×0.85): there is less spatial redundancy per pixel to exploit at low
    /// resolutions, which is why real encoding ladders aren't linear in pixel
    /// count. That factor puts 480p Normal at 700 Kbps rather than 600.
    ///
    /// Sized for HEVC, which `downloadStreamURL` always requests. An
    /// H.264-shaped ladder would sit near 0.12 bpp at High, past HEVC's quality
    /// knee and roughly double the size of a commercial streaming app's
    /// equivalent tier.
    func videoBitrate(preset: DownloadBitratePreset) -> Int {
        switch (self, preset) {
        case (.uhd4K, .high):      return 16_000_000
        case (.uhd4K, .normal):    return 10_000_000
        case (.uhd4K, .dataSaver): return 6_000_000
        case (.hd1080p, .high):      return 4_500_000
        case (.hd1080p, .normal):    return 3_000_000
        case (.hd1080p, .dataSaver): return 1_500_000
        case (.hd720p, .high):      return 2_250_000
        case (.hd720p, .normal):    return 1_500_000
        case (.hd720p, .dataSaver): return 750_000
        case (.sd480p, .high):      return 1_100_000
        case (.sd480p, .normal):    return 700_000
        case (.sd480p, .dataSaver): return 350_000
        }
    }

    /// The default tier for this device class: 720p on iPhone, 1080p on iPad.
    ///
    /// Grounded in angular resolution. Visual acuity tops out near 60 pixels
    /// per degree; at each class's real video area and viewing distance, 720p
    /// resolves to ~62 ppd on iPhone — already at the limit, so 1080p buys
    /// detail the eye cannot separate — but only ~39 ppd on a 13" iPad, where
    /// 1080p lands at ~58 ppd. Even the smallest iPad reaches only ~45 ppd at
    /// 720p.
    ///
    /// The consequence is intended: iPad downloads barely shrink, taking their
    /// savings from stream-copy passthrough and the source-bitrate cap rather
    /// than from the ladder.
    ///
    /// Branches on idiom rather than assuming a phone, since the tvOS and macOS
    /// ports will want 1080p or higher. Preferences are device-wide and never
    /// synced, so a per-device default can't conflict across devices.
    static var deviceClassDefault: DownloadResolution {
        #if os(iOS)
        return DeviceIdentity.isPad ? .hd1080p : .hd720p
        #else
        return .hd1080p
        #endif
    }

    /// `displayName` with "(Default)" appended for `deviceClassDefault`, shared
    /// by every Resolution picker so they can't drift apart. Marks the tier the
    /// app would choose, not the one currently selected, so "(Default)" stays
    /// put when a different tier is picked.
    ///
    /// Not folded into `displayName`, which also appears on a downloaded item's
    /// detail page where "(Default)" would be meaningless, or misleading for an
    /// item downloaded at another tier.
    var pickerDisplayName: String {
        guard self == Self.deviceClassDefault else { return displayName }
        return String(localized: "\(displayName) (Default)")
    }
}

/// Quality preset within a `DownloadResolution` tier. Audio is always AAC-LC
/// stereo, so only its bitrate varies by preset, independently of resolution —
/// unlike video bitrate, which is a function of both.
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

    /// 160/128/96 Kbps for High/Normal/Data Saver. AAC-LC stereo is transparent
    /// well below 192 Kbps, so a higher top rung would pay for nothing. Worth
    /// about 1% of a download's size.
    var audioBitrate: Int {
        switch self {
        case .high: return 160_000
        case .normal: return 128_000
        case .dataSaver: return 96_000
        }
    }

    /// Jellyfin's `MaxFramerate`, or `nil` for no cap. Only Data Saver caps, at
    /// 30fps: a no-op for the 23.976/24/25fps nearly all film and TV content
    /// runs at, and a large saving on genuine 50/60fps sources. Not applied to
    /// Normal or High, where halving a 60fps source would be a visible change
    /// nobody asked for.
    var maxFramerate: Int? {
        switch self {
        case .high, .normal: return nil
        case .dataSaver: return 30
        }
    }

    /// "High (4.5 Mbps)". The bitrate depends on the `DownloadResolution` tier
    /// this preset is paired with, so that tier is a parameter rather than
    /// `displayName`'s fixed label, letting a quality picker show real numbers.
    ///
    /// Reflects the shipped ladder only, with no visibility into a
    /// `DownloadQualityLadderStore` override. A picker that should honour one —
    /// every picker in the app today — resolves the effective bitrate itself and
    /// calls `displayName(bitrate:)`. This overload remains for call sites that
    /// want the stock number regardless.
    func displayName(in resolution: DownloadResolution) -> String {
        displayName(bitrate: resolution.videoBitrate(preset: self))
    }

    /// `displayName(in:)`'s VoiceOver counterpart, spelling out "Mbps" and
    /// otherwise formatting identically. Shipped-ladder-only, as that one is.
    func accessibilityDisplayName(in resolution: DownloadResolution) -> String {
        accessibilityDisplayName(bitrate: resolution.videoBitrate(preset: self))
    }

    /// `displayName(in:)`'s rendering from a bitrate passed directly rather than
    /// derived from the shipped ladder, for a picker honouring a
    /// `DownloadQualityLadderStore` override.
    func displayName(bitrate: Int) -> String {
        "\(displayName) (\(Self.mbpsText(bitrate)) Mbps)"
    }

    /// `displayName(bitrate:)`'s VoiceOver counterpart.
    func accessibilityDisplayName(bitrate: Int) -> String {
        "\(displayName) (\(Self.mbpsText(bitrate)) megabits per second)"
    }

    /// Whole numbers render bare ("3"), fractional ones to two places with
    /// trailing zeros trimmed ("4.5", "0.75"). The ladder has rungs at both
    /// 2.25 and 1.5 Mbps, so one decimal place can't separate every pair.
    private static func mbpsText(_ bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1_000_000
        if mbps == mbps.rounded() { return String(format: "%.0f", mbps) }
        return String(format: "%.2f", mbps)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
}

/// The transcode parameters `downloadStreamURL` sends for one download, after
/// applying `DownloadTranscodeCalculator.target`'s never-exceed-the-source rule.
struct DownloadTranscodeTarget: Equatable {
    var maxWidth: Int
    var maxHeight: Int
    /// Bits/sec.
    var videoBitrate: Int
    /// Jellyfin's `VideoProfile`, always `"main10"`. In theory 10-bit HEVC
    /// encodes a few percent more efficiently than 8-bit even for SDR input,
    /// and every iOS device that hardware-decodes HEVC decodes Main10.
    ///
    /// In practice a no-op on a VideoToolbox-encoding server, which returns
    /// `Main`/`yuv420p` 8-bit whether or not the param is sent. Kept because it
    /// costs nothing and a `libx265` server would honour it — but the
    /// efficiency gain isn't something this app currently gets.
    var videoProfile: String
    /// Jellyfin's `MaxFramerate`, or `nil` to omit the param entirely.
    var maxFramerate: Int?
    /// Whether the source's video track can be copied into the output MP4
    /// untouched. `DownloadTranscodeCalculator.target` has the conditions.
    var videoStreamCopyEligible: Bool
    /// Jellyfin's `VideoCodec`, comma-joined. Normally `["hevc"]`; the
    /// stream-copy path appends the source's codec, which Jellyfin requires
    /// before it will copy that stream.
    var requestedVideoCodecs: [String]
}

/// Resolution and bitrate capping, split out from
/// `JellyfinAPIClient.downloadStreamURL` so it is testable with no mock network.
enum DownloadTranscodeCalculator {
    /// Tiers cap `MaxWidth`/`MaxHeight` at `min(tierMax, sourceDimension)`, and
    /// video bitrate at the source's own when that is lower, so a low-bitrate
    /// source is never inflated. A `nil` source dimension or bitrate — metadata
    /// Jellyfin didn't report — skips that cap and uses the tier's max.
    ///
    /// `sourceBitrate` must be the video stream's own bitrate, not the media
    /// source's container bitrate, which includes audio and subtitle tracks and
    /// so caps a video-only target less aggressively than intended.
    ///
    /// The bitrate is looked up from `effectiveTier` rather than the requested
    /// `resolution`. Otherwise a 480p-only source with 1080p requested caps
    /// `maxWidth`/`maxHeight` to SD correctly but still takes 1080p's ladder
    /// rung, inflating a download that will only ever render at 480p.
    /// `min(..., sourceBitrate)` doesn't catch this: a source's own bitrate can
    /// exceed even the requested tier's rung — an old high-bitrate SD encode,
    /// say — so that cap never steps down to the achieved resolution.
    ///
    /// `videoBitrateLadder` looks up the rung, defaulting to the shipped
    /// `DownloadResolution.videoBitrate(preset:)` table. Real download call
    /// sites pass `DownloadQualityLadderStore().videoBitrate(resolution:preset:)`
    /// so a user's override reaches the transcode request and not only the
    /// settings screen. An injectable closure rather than stored state, keeping
    /// this type a pure function.
    static func target(
        resolution: DownloadResolution,
        preset: DownloadBitratePreset,
        isSourceHDR: Bool,
        sourceWidth: Int?,
        sourceHeight: Int?,
        sourceBitrate: Int?,
        sourceVideoCodec: String? = nil,
        videoBitrateLadder: (DownloadResolution, DownloadBitratePreset) -> Int = { $0.videoBitrate(preset: $1) }
    ) -> DownloadTranscodeTarget {
        let maxHeight = min(resolution.maxHeight, sourceHeight ?? resolution.maxHeight)
        let maxWidth = min(resolution.maxWidth, sourceWidth ?? resolution.maxWidth)
        let effectiveTier = effectiveTier(forAchievedHeight: maxHeight, notExceeding: resolution)
        let tierBitrate = videoBitrateLadder(effectiveTier, preset)
        let videoBitrate = min(tierBitrate, sourceBitrate ?? tierBitrate)
        let copyEligible = streamCopyEligible(
            resolution: resolution,
            tierBitrate: tierBitrate,
            isSourceHDR: isSourceHDR,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceBitrate: sourceBitrate,
            sourceVideoCodec: sourceVideoCodec
        )
        return DownloadTranscodeTarget(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            videoBitrate: videoBitrate,
            videoProfile: "main10",
            maxFramerate: preset.maxFramerate,
            videoStreamCopyEligible: copyEligible,
            requestedVideoCodecs: requestedVideoCodecs(
                streamCopyEligible: copyEligible, sourceVideoCodec: sourceVideoCodec
            )
        )
    }

    /// `["hevc"]`, the codec every download transcodes to. The stream-copy path
    /// appends the source's own codec, since Jellyfin copies only a stream whose
    /// codec the client asked for. `"h265"` normalises to `"hevc"` — both
    /// spellings occur — so the list can't carry a duplicate.
    private static func requestedVideoCodecs(streamCopyEligible: Bool, sourceVideoCodec: String?) -> [String] {
        guard streamCopyEligible, let source = sourceVideoCodec?.lowercased() else { return ["hevc"] }
        let normalized = source == "h265" ? "hevc" : source
        return normalized == "hevc" ? ["hevc"] : ["hevc", normalized]
    }

    /// Whether the source's video track already satisfies the requested tier, so
    /// Jellyfin can mux it into the output MP4 untouched
    /// (`AllowVideoStreamCopy=true`) instead of re-encoding.
    ///
    /// Re-encoding a file already inside the tier buys nothing and costs a
    /// second generation of lossy encoding plus minutes of server CPU. Audio is
    /// still transcoded to AAC-LC stereo, so the output keeps the MP4/AAC shape
    /// the offline path assumes.
    ///
    /// Every condition is load-bearing:
    /// - Codec is H.264 or HEVC. Anything else — VP9, AV1, MPEG-2, VC-1 —
    ///   either can't be muxed into MP4 or can't be decoded on target devices.
    /// - Resolution and bitrate already fit the tier, or the copy hands back a
    ///   bigger file than was asked for.
    /// - Source is SDR. A copy would preserve HDR, which is desirable, but
    ///   `DownloadedItem.isHDR` is hardcoded `false` on the assumption that
    ///   downloads are tone-mapped, and breaking that would make the offline UI
    ///   misreport what it holds. Lifting this is its own change.
    ///
    /// Unknown metadata counts as ineligible rather than fine: guessing wrong
    /// ships an uncapped original, the failure this path exists to prevent.
    private static func streamCopyEligible(
        resolution: DownloadResolution,
        tierBitrate: Int,
        isSourceHDR: Bool,
        sourceWidth: Int?,
        sourceHeight: Int?,
        sourceBitrate: Int?,
        sourceVideoCodec: String?
    ) -> Bool {
        guard !isSourceHDR,
              let codec = sourceVideoCodec?.lowercased(),
              codec == "h264" || codec == "hevc" || codec == "h265",
              let width = sourceWidth, let height = sourceHeight, let bitrate = sourceBitrate,
              width <= resolution.maxWidth, height <= resolution.maxHeight,
              bitrate <= tierBitrate
        else { return false }
        return true
    }

    /// The predicted size of a not-yet-started download, from the same
    /// `(videoBitrate + audioBitrate) * durationSeconds / 8` formula
    /// `DownloadedItem.estimatedTotalBytes` uses afterwards. Both route their
    /// video bitrate through `target(...)`, so the number
    /// `AdvancedDownloadOptionsView` shows can't drift from what the enqueued
    /// row settles on.
    ///
    /// `nil` with no runtime to estimate from, as for a live item whose
    /// `runTimeTicks` hasn't loaded; callers should omit the estimate rather
    /// than show `0 B`.
    static func estimatedTotalBytes(
        resolution: DownloadResolution,
        preset: DownloadBitratePreset,
        isSourceHDR: Bool,
        sourceWidth: Int?,
        sourceHeight: Int?,
        sourceBitrate: Int?,
        sourceVideoCodec: String? = nil,
        runtimeTicks: Int64?,
        videoBitrateLadder: (DownloadResolution, DownloadBitratePreset) -> Int = { $0.videoBitrate(preset: $1) }
    ) -> Int64? {
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        let resolvedTarget = target(
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, sourceBitrate: sourceBitrate,
            sourceVideoCodec: sourceVideoCodec, videoBitrateLadder: videoBitrateLadder
        )
        let durationSeconds = Double(runtimeTicks) / 10_000_000
        let totalBitsPerSecond = Double(resolvedTarget.videoBitrate) + Double(preset.audioBitrate)
        return Int64((totalBitsPerSecond * durationSeconds) / 8)
    }

    /// The tiers ascending by `maxHeight`, the order
    /// `effectiveTier(forAchievedHeight:notExceeding:)` scans — not
    /// `DownloadResolution`'s own descending `CaseIterable` order.
    private static let tiersByAscendingHeight: [DownloadResolution] = [.sd480p, .hd720p, .hd1080p, .uhd4K]

    /// The smallest tier covering `achievedHeight` without exceeding
    /// `requested`: the ladder rung matching this download's real output
    /// resolution. The caller has already clamped `achievedHeight` to
    /// `requested.maxHeight`, so `requested` is always a valid and maximal
    /// candidate and this only ever steps down.
    private static func effectiveTier(forAchievedHeight achievedHeight: Int, notExceeding requested: DownloadResolution) -> DownloadResolution {
        tiersByAscendingHeight.first { $0.maxHeight >= achievedHeight } ?? requested
    }
}
