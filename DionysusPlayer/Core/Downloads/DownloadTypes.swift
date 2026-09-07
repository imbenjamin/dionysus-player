import Foundation

/// Resolution tier for an offline download's transcode target — caps
/// `MaxWidth`/`MaxHeight` sent to Jellyfin's transcoder
/// (`JellyfinAPIClient.downloadStreamURL`). Never allowed to exceed the
/// source's own resolution — see `DownloadTranscodeCalculator.target`.
///
/// See `DOWNLOADS.md` for why the ladder is shaped the way it is; the short
/// version is in `videoBitrate(preset:)` below.
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
    /// The ladder is **constant bits-per-pixel-per-frame**, not a set of
    /// round numbers: each preset has a bpp target (High 0.095, Normal
    /// 0.062, Data Saver 0.032, measured at 24fps) applied across every
    /// tier, so a rung's quality means the same thing regardless of which
    /// resolution it's paired with. That property is the whole point of the
    /// table — **if you change a number here, check it still lands on its
    /// preset's bpp**, or the tiers stop being comparable.
    ///
    /// Smaller resolutions carry a slightly higher bpp target (480p ×1.15,
    /// 720p ×1.08, 4K ×0.85): there's less spatial redundancy per pixel to
    /// exploit at low resolutions, which is why real-world encoding ladders
    /// aren't linear in pixel count. That factor is what puts 480p Normal at
    /// 700 Kbps rather than the 600 a linear ladder would give.
    ///
    /// Numbers are sized for **HEVC**, which is what `downloadStreamURL`
    /// always requests. They were retuned on 2026-08-27 from an earlier
    /// H.264-shaped ladder whose High rungs sat at ~0.12 bpp — well past
    /// HEVC's quality knee, and the reason a default download ran roughly
    /// double the size of the equivalent tier on a commercial streaming app.
    /// The 720p tier was added in the same pass; without it the ladder
    /// jumped straight from 1080p to 480p, and 720p is precisely where
    /// Disney+ "Medium" and Prime Video "Better" both sit.
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

    /// The default tier for this device class — **720p on iPhone, 1080p on
    /// iPad**, rather than one number for everything.
    ///
    /// Grounded in angular resolution rather than taste. Human visual acuity
    /// tops out around 60 pixels per degree; at the video area and viewing
    /// distance each device class is actually used at, 720p resolves to
    /// ~62 ppd on an iPhone (i.e. already at the limit — 1080p there is spent
    /// on detail the eye cannot separate) but only ~39 ppd on a 13" iPad,
    /// where 1080p lands at ~58 ppd and is the right rung. Even the smallest
    /// iPad only reaches ~45 ppd at 720p.
    ///
    /// The consequence is deliberate and worth stating plainly: **iPad
    /// downloads barely shrink.** They get their savings from stream-copy
    /// passthrough and the source-bitrate cap instead of from the ladder.
    ///
    /// Branches on idiom rather than hardcoding a phone assumption because
    /// the tvOS/macOS ports will both want 1080p or higher. Preferences are
    /// device-wide and never synced (see `DownloadPreferencesStore`), so a
    /// per-device default can't produce a cross-device conflict.
    static var deviceClassDefault: DownloadResolution {
        #if os(iOS)
        return DeviceIdentity.isPad ? .hd1080p : .hd720p
        #else
        return .hd1080p
        #endif
    }

    /// `displayName`, with "(Default)" appended when this tier is
    /// `deviceClassDefault` — shared by every Resolution *picker*
    /// (`DownloadsSettingsView`'s device-wide picker and
    /// `AdvancedDownloadOptionsView`'s per-download override sheet), so the
    /// two stay visually consistent rather than drifting into separately
    /// hand-written label logic. Marks whichever tier the app would choose,
    /// not whatever is currently selected — pick a different tier in either
    /// picker and "(Default)" stays put on 720p/1080p.
    ///
    /// Deliberately not folded into `displayName` itself — that same label
    /// also appears on a downloaded item's own detail page, where
    /// "(Default)" would be meaningless, or, for an item downloaded at some
    /// other tier, actively misleading.
    var pickerDisplayName: String {
        guard self == Self.deviceClassDefault else { return displayName }
        return String(localized: "\(displayName) (Default)")
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

    /// Audio bitrate in bits/sec — 160/128/96 Kbps for High/Normal/Data
    /// Saver. Lowered from 192/160/96 on 2026-08-27: AAC-LC stereo is
    /// already transparent well below 192 Kbps, so the top rung was paying
    /// for nothing. Worth roughly 1% of a download's total size — kept for
    /// tidiness rather than because it moves the needle.
    var audioBitrate: Int {
        switch self {
        case .high: return 160_000
        case .normal: return 128_000
        case .dataSaver: return 96_000
        }
    }

    /// Frame-rate ceiling sent as Jellyfin's `MaxFramerate`, or `nil` for no
    /// cap. Only Data Saver caps, at 30fps: a no-op for the 23.976/24/25fps
    /// that essentially all film and TV content actually is, but a large
    /// saving on genuinely 50/60fps sources, which is exactly the trade
    /// someone picking "Data Saver" is asking for. Deliberately *not*
    /// applied to Normal/High, where halving the frame rate of a 60fps
    /// source would be a visible change nobody asked for.
    var maxFramerate: Int? {
        switch self {
        case .high, .normal: return nil
        case .dataSaver: return 30
        }
    }

    /// e.g. "High (4.5 Mbps)" — the actual video bitrate for this preset
    /// depends on which `DownloadResolution` tier it's paired with (see the
    /// bitrate ladder table), so this takes that tier as a parameter rather
    /// than being a fixed label like `displayName`. Used by the downloads
    /// settings quality picker so each row shows the real number, not just a
    /// vague "High"/"Normal"/"Data Saver" label.
    ///
    /// Always reflects the **shipped default** ladder — a fixed function of
    /// `resolution` alone, with no way to see a user's own
    /// `DownloadQualityLadderStore` override. Any picker that should reflect
    /// a customized ladder (every real one in the app today) must resolve
    /// the effective bitrate itself and call `displayName(bitrate:)`
    /// instead; this overload only remains for call sites that
    /// deliberately want the stock number regardless of overrides.
    func displayName(in resolution: DownloadResolution) -> String {
        displayName(bitrate: resolution.videoBitrate(preset: self))
    }

    /// `displayName(in:)`'s VoiceOver counterpart — "Mbps" read letter by
    /// letter ("M B P S") rather than as a word. Same
    /// whole-number-vs-fractional formatting as `displayName(in:)` itself,
    /// so the two only ever differ in how the unit is spelled out. Same
    /// "shipped default only" caveat as `displayName(in:)` applies here too.
    func accessibilityDisplayName(in resolution: DownloadResolution) -> String {
        accessibilityDisplayName(bitrate: resolution.videoBitrate(preset: self))
    }

    /// Same rendering as `displayName(in:)`, but takes the video bitrate
    /// (bits/sec) directly rather than deriving it from the shipped ladder —
    /// what a picker that needs to reflect a `DownloadQualityLadderStore`
    /// override calls, passing that store's own
    /// `videoBitrate(resolution:preset:)` result in place of
    /// `resolution.videoBitrate(preset:)`.
    func displayName(bitrate: Int) -> String {
        "\(displayName) (\(Self.mbpsText(bitrate)) Mbps)"
    }

    /// `displayName(bitrate:)`'s VoiceOver counterpart, same relationship as
    /// `accessibilityDisplayName(in:)` has to `displayName(in:)`.
    func accessibilityDisplayName(bitrate: Int) -> String {
        "\(displayName) (\(Self.mbpsText(bitrate)) megabits per second)"
    }

    /// Whole numbers render without a decimal ("3"), fractional ones to two
    /// places with trailing zeros trimmed ("4.5", "0.75") — the ladder has
    /// rungs at both 2.25 and 1.5 Mbps, so one decimal place isn't enough to
    /// tell every pair of rungs apart.
    private static func mbpsText(_ bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1_000_000
        if mbps == mbps.rounded() { return String(format: "%.0f", mbps) }
        return String(format: "%.2f", mbps)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
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
    /// Jellyfin's `VideoProfile` param — always `"main10"`, previously
    /// `"main"` for SDR sources and `"main10"` only for HDR ones. In theory
    /// 10-bit HEVC encodes a few percent more efficiently than 8-bit even
    /// for SDR input (more headroom in the encoder's internal precision,
    /// less banding to spend bits correcting), and every iOS device that can
    /// hardware-decode HEVC can decode Main10.
    ///
    /// **In practice this is currently a no-op**, confirmed by probing the
    /// reference server (Apple Silicon, VideoToolbox hardware encoding):
    /// output comes back `Main`/`yuv420p` 8-bit whether the param is sent or
    /// not. Kept because it costs nothing, is the correct thing to ask for,
    /// and a server using software `libx265` would honour it — but don't
    /// count the efficiency gain as something this app is actually getting.
    var videoProfile: String
    /// Jellyfin's `MaxFramerate`, or `nil` to omit the param entirely.
    var maxFramerate: Int?
    /// Whether the source's video track can be copied into the output MP4
    /// untouched instead of re-encoded — see
    /// `DownloadTranscodeCalculator.target` for the conditions.
    var videoStreamCopyEligible: Bool
    /// What to send as Jellyfin's `VideoCodec`, comma-joined. Normally just
    /// `["hevc"]`; on the stream-copy path the source's own codec is
    /// appended, because Jellyfin refuses to copy a stream whose codec isn't
    /// among the ones the client asked for (see
    /// `JellyfinAPIClient.downloadStreamURL`).
    var requestedVideoCodecs: [String]
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
    ///
    /// `sourceBitrate` must be the **video stream's own** bitrate, not the
    /// media source's container bitrate: the latter includes audio and
    /// subtitle tracks, so comparing it against a video-only target caps
    /// less aggressively than intended. `DownloadManager` reads it off the
    /// video `MediaStream` and only falls back to the container figure when
    /// the server didn't report a per-stream one.
    ///
    /// The bitrate itself is looked up from `effectiveTier`, not `resolution`
    /// (the tier the user actually requested) directly — a real bug, found
    /// live (2026-08-19): a source only available in 480p, with a 1080p tier
    /// requested, correctly capped `maxWidth`/`maxHeight` down to the
    /// source's own SD dimensions, but still looked its bitrate up from the
    /// *requested* 1080p tier's own ladder rung (3 Mbps at "Normal") rather
    /// than 480p's (1.2 Mbps) — needlessly inflating the download for video
    /// that was only ever going to render at 480p regardless. `min(...,
    /// sourceBitrate)` alone doesn't catch this: a source can easily have
    /// its own bitrate well above even the *requested* tier's ladder rung
    /// (an old high-bitrate SD encode, say), so that cap alone never pulls
    /// the number back down to match the achieved resolution the way
    /// `effectiveTier` does.
    /// `videoBitrateLadder` is what actually looks up a rung's bitrate —
    /// defaults to the shipped `DownloadResolution.videoBitrate(preset:)`
    /// table, which is what every existing caller (and every test in
    /// `DownloadTypesTests`) gets without changes. Real download call sites
    /// (`JellyfinAPIClient.downloadStreamURL`, `DownloadManager.enqueue`)
    /// pass `DownloadQualityLadderStore().videoBitrate(resolution:preset:)`
    /// instead, so a user's own override actually reaches the transcode
    /// request rather than only the settings screen that edits it. Kept as
    /// an injectable closure rather than a stored property on this `enum`
    /// (which has none) so the pure-function/no-mock-network-layer
    /// unit-testability this type was split out for isn't lost.
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

    /// `["hevc"]` normally — the codec every download is transcoded to. On
    /// the stream-copy path the source's own codec is appended, since
    /// Jellyfin will only copy a stream whose codec the client actually
    /// asked for. `"h265"` is normalised to `"hevc"` (both spellings occur
    /// in the wild) so the list can't end up with a redundant duplicate.
    private static func requestedVideoCodecs(streamCopyEligible: Bool, sourceVideoCodec: String?) -> [String] {
        guard streamCopyEligible, let source = sourceVideoCodec?.lowercased() else { return ["hevc"] }
        let normalized = source == "h265" ? "hevc" : source
        return normalized == "hevc" ? ["hevc"] : ["hevc", normalized]
    }

    /// Whether the source's video track already satisfies everything the
    /// requested tier asks for, so Jellyfin can mux it into the output MP4
    /// untouched (`AllowVideoStreamCopy=true`) rather than re-encoding it.
    ///
    /// Worth doing because re-encoding a file that's already inside the tier
    /// buys nothing and costs twice: a second generation of lossy encoding,
    /// and minutes of server CPU per download. The audio track is still
    /// transcoded to AAC-LC stereo either way, so the output stays the
    /// MP4/AAC shape the rest of the offline path assumes.
    ///
    /// Every condition has to hold, and each one is load-bearing:
    /// - **Codec is H.264 or HEVC** — anything else (VP9, AV1, MPEG-2,
    ///   VC-1) either can't be muxed into MP4 or can't be decoded on the
    ///   devices this app targets.
    /// - **Resolution and bitrate already fit** the tier, or copying would
    ///   silently hand back a bigger file than the user asked for.
    /// - **Source is SDR.** A stream copy would faithfully preserve HDR,
    ///   which is genuinely desirable — but `DownloadedItem.isHDR` is
    ///   hardcoded `false` on the assumption that every download is
    ///   tone-mapped (see `DownloadManager.enqueue`), and quietly breaking
    ///   that invariant would make the offline UI lie about what it holds.
    ///   Lifting this is the natural next step, not a rider on this one.
    ///
    /// Unknown metadata (a `nil` codec, dimension, or bitrate) is treated as
    /// ineligible rather than assumed-fine: guessing wrong here means
    /// shipping the user an uncapped original, which is the exact failure
    /// this whole path exists to prevent.
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

    /// The predicted download size in bytes for a not-yet-started
    /// download — same `(videoBitrate + audioBitrate) * durationSeconds / 8`
    /// formula `DownloadedItem.estimatedTotalBytes` uses once a download
    /// already exists, computed here ahead of time from a source's own
    /// metadata instead. Routing both through `target(...)` for the video
    /// bitrate keeps the two in lockstep — the number
    /// `AdvancedDownloadOptionsView` shows before tapping Download can never
    /// drift from what the real enqueued row settles on afterward, because
    /// there's only one place the capping logic lives.
    ///
    /// `nil` when there's no runtime to estimate from — happens for a live
    /// item whose `BaseItemDto.runTimeTicks` hasn't loaded, and the caller
    /// should simply omit the estimate rather than show a nonsensical `0 B`.
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

    /// The four resolution tiers, smallest-to-largest by `maxHeight` — the
    /// order `effectiveTier(forAchievedHeight:notExceeding:)` scans in to
    /// find the ladder rung that actually matches an achieved resolution,
    /// rather than relying on `DownloadResolution`'s own (descending)
    /// `CaseIterable` order.
    private static let tiersByAscendingHeight: [DownloadResolution] = [.sd480p, .hd720p, .hd1080p, .uhd4K]

    /// The smallest tier whose own `maxHeight` still covers `achievedHeight`
    /// — i.e. the bitrate ladder rung that actually matches this download's
    /// real output resolution — without ever exceeding `requested` (the
    /// tier the user actually chose in settings). `achievedHeight` is
    /// always already clamped to `requested.maxHeight` by the caller, so
    /// `requested` itself is always a valid — and the largest possible —
    /// candidate; this only ever steps *down* from it, never up.
    ///
    /// Adding the 720p tier changed this function's behaviour for every
    /// existing user, not just those who pick 720p: a 720p source with a
    /// higher tier requested used to round up to 1080p's rung and download
    /// at 3 Mbps, and now correctly gets 720p's 1.5.
    private static func effectiveTier(forAchievedHeight achievedHeight: Int, notExceeding requested: DownloadResolution) -> DownloadResolution {
        tiersByAscendingHeight.first { $0.maxHeight >= achievedHeight } ?? requested
    }
}
