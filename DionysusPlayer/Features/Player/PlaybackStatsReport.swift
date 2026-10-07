import AVFAudio
import SwiftUI
import UIKit

/// The playback stats rows, built once for both apps: iOS's
/// `PlaybackStatsOverlay` pages them, the Apple TV's `TVStatsPanel` shows them
/// on one page. Labels are technical and stay unlocalized, as they were;
/// section titles are localized.
///
/// `@MainActor` because its statics read `UIScreen` and `UIDevice`.
@MainActor
enum PlaybackStatsReport {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        /// Keys the value's accessibility identifier where the label isn't
        /// unique (Video and Audio both have a "Decoder").
        let id: String

        init(_ label: String, _ value: String, id: String? = nil) {
            self.label = label
            self.value = value
            self.id = id ?? label
        }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// The readings that come from UIKit and AVFAudio rather than the playback
    /// engine, so they're polled by the view instead of via `PlaybackStats`.
    struct DeviceReadings: Equatable {
        var audioOutputRoute: String?
        /// Channel count of the device's current audio route — distinct from
        /// `stats.audioChannels`, the media's own layout. See `audio`.
        var audioOutputChannelCount: Int?
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// Brightness headroom the display has for HDR above SDR white (1.0 =
        /// none). Pairs with `PlaybackStats.displayColorFormat`: an HDR source
        /// at headroom 1.0 is getting no HDR boost, whatever the format label
        /// says.
        var edrHeadroom: CGFloat = 1

        @MainActor
        static func current() -> DeviceReadings {
            DeviceReadings(
                audioOutputRoute: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName,
                audioOutputChannelCount: AVAudioSession.sharedInstance().outputNumberOfChannels,
                thermalState: ProcessInfo.processInfo.thermalState,
                edrHeadroom: UIScreen.main.currentEDRHeadroom
            )
        }
    }
}

// MARK: - Sections

extension PlaybackStatsReport {
    static func video(_ stats: PlaybackStats, sourceVideoStream stream: MediaStream?) -> Section {
        // `stats.videoSize`/`.frameRate`/`.bitrate` come from AetherEngine's
        // source probe, which never runs on the `nativeRemoteHLS` bypass
        // route — so all three stay `nil` for the life of such a session, not
        // just at startup. Falls back to `sourceVideoStream`, Jellyfin's probe
        // of the same file, describing the source; the Streaming section's
        // rows describe the transcode target.
        var rows: [Row] = [
            Row("Resolution", stats.videoSize ?? sourceResolutionText(stream) ?? "—"),
            Row("Frame Rate", stats.frameRate ?? sourceFrameRateText(stream) ?? "—"),
            Row("Bitrate", stats.bitrate ?? sourceBitrateText(stream) ?? "—"),
            // Same fallback again. Jellyfin reports these in libav's names
            // too, and `StreamFormatDescription` formats both, so a row reads
            // the same whichever probe filled it. A source has one video
            // stream, so mixing the two per row can't describe two different
            // streams.
            Row("Codec", stats.videoCodec ?? StreamFormatDescription.codec(stream) ?? "—"),
            Row("Container", stats.container ?? "—"),
            Row("Pixel Format", stats.pixelFormat ?? StreamFormatDescription.pixelFormat(stream) ?? "—"),
            Row("Color", stats.colorDescription ?? StreamFormatDescription.color(stream) ?? "—"),
            Row("Source Color", stats.sourceColorFormat)
        ]
        if stats.sourceColorFormat.hasPrefix("Dolby Vision") {
            rows.append(Row("Enhancement Layer", describeEnhancementLayer(stream?.videoRangeType)))
        }
        // Reads "AVPlayer" on a server transcode, where AetherEngine names no
        // decoder: AVPlayer decodes the server's HLS itself.
        rows.append(Row("Decoder", stats.videoDecoder ?? "—"))
        // Software route only, and constant for a session, so the row coming
        // and going never moves the box mid-session.
        if let decoded = stats.decodedFormat {
            rows.append(Row("Decoded", decoded))
        }
        rows.append(Row("Backend", stats.backend))
        rows.append(Row("Route", stats.route))
        return Section(title: String(localized: "Video"), rows: rows)
    }

    /// "Source Channels" is the media's own layout ("5.1", "Atmos", ...);
    /// "Output Channels" is what the current route is configured for (2 for
    /// built-in speakers whatever the source, up to 8 over HDMI/AirPlay). Kept
    /// as separate rows because a 7.1 source plays over stereo speakers
    /// downmixed — the same split `video`/`display` draw between
    /// "Source Color" and "Displayed Color".
    ///
    /// "Profile" is where TrueHD Atmos and DTS:X show ("Dolby TrueHD + Dolby
    /// Atmos"), which "Source Channels" can't: its "Atmos" covers E-AC-3 JOC
    /// only. Next to "Decoder" ("TrueHD → FLAC bridge") it shows the Atmos is
    /// in the source and not reaching the output.
    static func audio(_ stats: PlaybackStats, sourceAudioStream: MediaStream?, readings: DeviceReadings) -> Section {
        // Unlike video, a source has several audio tracks, and Jellyfin's is
        // the default one rather than necessarily the one playing. So these
        // fall back only when the engine knows nothing about the active track
        // (`audioChannels` nil), never to fill one field the engine left
        // empty — an E-AC-3 track with no profile would otherwise borrow
        // another track's.
        let engineKnowsTrack = stats.audioChannels != nil
        let fallback = engineKnowsTrack ? nil : sourceAudioStream
        return Section(title: String(localized: "Audio"), rows: [
            Row("Decoder", stats.audioDecoder ?? "—", id: "Audio Decoder"),
            // Same probe-never-runs gap as the video section — falls back to
            // `sourceAudioStream`, Jellyfin's probe of the default audio track.
            Row("Source Channels", stats.audioChannels ?? sourceChannelsText(sourceAudioStream) ?? "—"),
            Row("Profile", stats.audioProfile ?? fallback?.profile ?? "—"),
            Row("Sampling", stats.audioSampling ?? StreamFormatDescription.audioSampling(fallback) ?? "—"),
            Row("Output Route", readings.audioOutputRoute ?? "—"),
            Row("Output Channels", describeChannelCount(readings.audioOutputChannelCount))
        ])
    }

    /// `zoomMode` is `nil` on the Apple TV, which has no zoom.
    static func playback(_ stats: PlaybackStats, state: PlaybackState, zoomMode: VideoZoomMode?) -> Section {
        var rows = [
            Row("State", describe(state)),
            Row("Position", "\(formatTime(stats.currentTime)) / \(formatTime(stats.duration))"),
            Row("Buffered", describeBuffered(seconds: stats.bufferedSeconds, bytes: stats.bufferedBytes)),
            // Live, from AetherEngine's 1 Hz sampler — the first rows to read
            // when playback stutters: is the link keeping up, and is the
            // display dropping frames?
            Row("Live Bitrate", stats.liveBitrate ?? "—"),
            Row("Throughput", stats.networkThroughput ?? "—"),
            Row("Frames", stats.frames ?? "—")
        ]
        if let zoomMode { rows.append(Row("Zoom", zoomMode == .fill ? "Fill" : "Fit")) }
        return Section(title: String(localized: "Playback"), rows: rows)
    }

    static func display(_ stats: PlaybackStats, readings: DeviceReadings) -> Section {
        Section(title: String(localized: "Display"), rows: [
            Row("Screen", "\(Int(screenSize.width))×\(Int(screenSize.height)) pt"),
            Row("Displayed Color", stats.displayColorFormat),
            Row("Refresh Rate", "\(refreshRateHz) Hz"),
            Row("EDR Headroom", String(format: "%.2fx", readings.edrHeadroom)),
            Row("Thermal State", describe(readings.thermalState))
        ])
    }

    /// Server-side diagnostics: the server's version, its view of this
    /// session's play method, and while transcoding the transcode parameters.
    /// See `PlayerViewModel.serverVersion`/`.streamingSession` for why these
    /// are separate, slower-polled requests rather than `PlaybackStats`.
    ///
    /// For offline playback there's no live session — both refresh methods
    /// no-op, leaving those properties `nil` forever — so this collapses to a
    /// single "Download" play method row.
    static func streaming(isOffline: Bool, serverVersion: String?, session: SessionInfoDto?) -> Section {
        guard !isOffline else {
            return Section(title: String(localized: "Playback Source"), rows: [Row("Play Method", "Download")])
        }
        var rows = [
            Row("Jellyfin Server", serverVersion ?? "—"),
            Row("Play Method", describePlayMethod(session?.playState?.playMethod))
        ]
        if let transcoding = session?.transcodingInfo {
            rows.append(Row("Transcode Video", transcoding.videoCodec ?? "—"))
            rows.append(Row("Transcode Audio", transcoding.audioCodec ?? "—"))
            rows.append(Row("Transcode Bitrate", transcoding.bitrate.map(formatMbps) ?? "—"))
            if let width = transcoding.width, let height = transcoding.height {
                rows.append(Row("Transcode Size", "\(width)×\(height)"))
            }
            rows.append(Row("Completion", transcoding.completionPercentage.map { String(format: "%.0f%%", $0) } ?? "—"))
            if let reasons = transcoding.transcodeReasons, !reasons.isEmpty {
                rows.append(Row("Reasons", reasons.joined(separator: ", ")))
            }
        }
        return Section(title: String(localized: "Streaming"), rows: rows)
    }

    /// Build/environment info, static for the life of the process, so it's
    /// read once into `static let`s rather than polled.
    static func build() -> Section {
        Section(title: String(localized: "Build"), rows: [
            Row("App Version", appVersion),
            Row("AetherEngine Version", aetherEngineVersion),
            Row("Device", deviceModelIdentifier),
            Row(osVersionLabel, osVersion)
        ])
    }
}

// MARK: - Readings and formatting

extension PlaybackStatsReport {
    static let screenSize = UIScreen.main.bounds.size
    static let refreshRateHz = UIScreen.main.maximumFramesPerSecond

    /// "1.0 (1)" — `CFBundleShortVersionString` plus build number, the pairing
    /// Settings and the App Store show.
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }()

    /// Read from the linked engine itself — see `AetherEngineVersion`.
    static let aetherEngineVersion = AetherEngineVersion.current

    /// Hardware identifier (e.g. "iPhone15,1"), not the marketing name: it
    /// maps 1:1 to a chip/display/decoder combination. `uname`'s `machine`
    /// field is the only way to read it; there's no public UIKit API.
    static let deviceModelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }()

    /// "tvOS Version" on the Apple TV, "iOS Version" on iOS (the row's label
    /// is also its accessibility id, which iOS's journeys read).
    static let osVersionLabel: String = {
        #if os(tvOS)
        "tvOS Version"
        #else
        "iOS Version"
        #endif
    }()
    static let osVersion = UIDevice.current.systemVersion

    /// The "1.0"/"2.0"/"5.1"/"7.1" labeling `AetherPlaybackEngine
    /// .describeChannels` uses, applied to the device route's channel count so
    /// the two rows compare at a glance. No Atmos case:
    /// `AVAudioSession.outputNumberOfChannels` is a plain count with no way to
    /// tell whether an Atmos bed rides on it.
    static func describeChannelCount(_ count: Int?) -> String {
        guard let count, count > 0 else { return "—" }
        switch count {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count)ch"
        }
    }

    /// `seconds` is the gate; `bytes` comes from the same native-only source
    /// (see `PlaybackStats.bufferedBytes`) but is treated as optional in case
    /// it lags a tick at session startup.
    static func describeBuffered(seconds: Double?, bytes: Int64?) -> String {
        guard let seconds else { return "N/A" }
        let secondsText = String(format: "%.1fs", seconds)
        guard let bytes else { return secondsText }
        return "\(secondsText) (\(formatKB(bytes)))"
    }

    static func formatKB(_ bytes: Int64) -> String {
        "\((bytes / 1024).formatted()) KB"
    }

    /// `MediaStream.videoRangeType` is Jellyfin's server-side ffprobe result,
    /// the same value other clients surface. Only meaningful alongside a Dolby
    /// Vision `sourceColorFormat`: "DOVI" is a single-layer source with no base
    /// layer (DV Profile 5), the "DOVIWith..." cases name the format a non-DV
    /// panel falls back to.
    static func describeEnhancementLayer(_ videoRangeType: String?) -> String {
        switch videoRangeType {
        case "DOVI": return "None (single-layer)"
        case "DOVIWithHDR10": return "HDR10"
        case "DOVIWithHDR10Plus": return "HDR10+"
        case "DOVIWithHLG": return "HLG"
        case "DOVIWithSDR": return "SDR"
        case "DOVIInvalid": return "Invalid"
        default: return "—"
        }
    }

    /// Jellyfin's `PlayMethod`, as reported by `/Sessions`. `"DirectPlay"` and
    /// `"DirectStream"` both read as "Direct Play" since neither transcodes;
    /// anything else, including an unrecognized future value, passes through
    /// as-is rather than being mapped to the wrong label.
    static func describePlayMethod(_ raw: String?) -> String {
        guard let raw else { return "—" }
        switch raw {
        case "DirectPlay", "DirectStream": return "Direct Play"
        case "Transcode": return "Transcoding"
        default: return raw
        }
    }

    static func formatMbps(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// Source-probe fallback for "Resolution" when AetherEngine's value is
    /// unavailable — see `video`.
    static func sourceResolutionText(_ stream: MediaStream?) -> String? {
        guard let stream, let width = stream.width, let height = stream.height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// Fallback for "Frame Rate". Prefers `realFrameRate` (measured from the
    /// file) over the coarser container-level `averageFrameRate`, like
    /// `MediaItem`'s technical-details formatting. `"%.3g fps"` matches
    /// `AetherPlaybackEngine.stats`, so the row reads the same whichever source
    /// populated it.
    static func sourceFrameRateText(_ stream: MediaStream?) -> String? {
        guard let rate = stream?.realFrameRate ?? stream?.averageFrameRate, rate > 0 else { return nil }
        return String(format: "%.3g fps", rate)
    }

    /// Fallback for "Bitrate". The stream's own `MediaStream.bitRate`, not
    /// `MediaSourceInfo.bitrate`, which covers the whole container and is
    /// inflated by the file's audio tracks.
    static func sourceBitrateText(_ stream: MediaStream?) -> String? {
        guard let bitRate = stream?.bitRate, bitRate > 0 else { return nil }
        return formatMbps(bitRate)
    }

    /// Fallback for "Source Channels". Jellyfin gives
    /// `audioSpatialFormat`/`channelLayout` rather than a numeric count, so no
    /// "1.0"/"5.1"/"7.1" normalization: its layout string is informative as-is.
    static func sourceChannelsText(_ stream: MediaStream?) -> String? {
        guard let stream else { return nil }
        if stream.audioSpatialFormat == "DolbyAtmos" { return "Atmos" }
        return stream.channelLayout?.capitalized
    }

    static func describe(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "Idle"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .seeking: return "Seeking"
        case .buffering: return "Buffering"
        case .reconnecting: return "Reconnecting"
        case .ended: return "Ended"
        case .failed(let failure): return "Failed (\(failure.message))"
        }
    }

    static func describe(_ thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
