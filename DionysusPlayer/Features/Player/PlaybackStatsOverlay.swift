import SwiftUI
import UIKit
import AVFAudio

/// The landscape "stats for nerds" panel, toggled by the info button in
/// `PlayerControlsOverlay`'s top-right group. Its own layer between the video
/// surface and `PlayerControlsOverlay` in `PlayerView`'s `ZStack`, not folded
/// into the controls overlay, so it stays visible through the controls'
/// auto-hide fade: `isVisible` (`PlayerView`'s `showPlaybackStats`) drives it,
/// never `showControls`.
///
/// Anchored top-trailing, since `PlayerControlsOverlay`'s title row and close
/// button own the top-leading corner.
///
/// Always mounted, with `isVisible` driving `.opacity` rather than being
/// conditionally inserted: this view's frame is the same whether or not it has
/// anything to show, so opacity alone never changes what the `ZStack` reports
/// as its size. Conditional mounting forced the whole `ZStack` through a fresh
/// layout pass on every toggle, visibly shifting the video layer as
/// `AetherPlayerSurface`'s bridged `AVPlayerLayer`/`AVSampleBufferDisplayLayer`
/// re-laid out with it.
///
/// Content is paginated (`currentPage`/`Self.pageCount`) rather than one
/// screenful: a transcode session's Streaming section can push the combined
/// six sections taller than an iPhone's landscape height, running off the
/// bottom and colliding with the transport row above it in the `ZStack`. Every
/// page still mounts — see `content` — which is what keeps the box a constant
/// size across a page tap.
///
/// Only the visible box is tappable to page through, which is why it needs its
/// own `.contentShape`/`.onTapGesture` rather than this view's usual
/// passthrough. A tap on the surrounding transparent frame still falls through
/// to `PlayerView`'s show/hide-controls gesture on the video surface.
struct PlaybackStatsOverlay: View {
    let viewModel: PlayerViewModel
    /// `PlayerView`'s zoom-mode state, passed in rather than read off the
    /// engine because it's view-local UI state.
    let zoomMode: VideoZoomMode
    let isVisible: Bool

    @State private var stats: PlaybackStats?
    /// The three device readings below come from UIKit/AVFAudio rather than the
    /// playback engine, so they're polled here instead of via `PlaybackStats`.
    @State private var audioOutputRoute: String?
    /// Channel count of the device's current audio route — distinct from
    /// `stats.audioChannels`, the media's own layout. See `audioSection`.
    @State private var audioOutputChannelCount: Int?
    @State private var thermalState: ProcessInfo.ThermalState = .nominal
    /// Brightness headroom the display has for HDR above SDR white (1.0 =
    /// none). Pairs with `PlaybackStats.displayColorFormat`: an HDR source at
    /// headroom 1.0 is getting no HDR boost, whatever the format label says.
    @State private var edrHeadroom: CGFloat = 1

    /// Which of `Self.pageCount` pages is showing — advanced by tapping the
    /// panel (`advancePage()`), looping past the last. Reset to `0` when the
    /// panel hides, so a reopen starts from the beginning.
    @State private var currentPage = 0
    /// Two fixed pages — "what's playing" (Video/Audio/Playback) and
    /// "device/server" (Display/Streaming/Build) — rather than measuring
    /// available height at runtime. `GeometryReader` is avoided for the same
    /// reason as in `PlayerControlsOverlay.estimatedHeight(for:)`: the measured
    /// view renders at zero size. The cost is not adapting to how much content
    /// each page actually has.
    private static let pageCount = 2

    /// Slow relative to the ~10 Hz playback clock: bitrate, decoder, buffer
    /// depth and thermal state don't change faster, and a diagnostic overlay
    /// shouldn't add busywork to an often decode-bound screen. Nothing pushes
    /// `PlaybackEngine.stats` updates, so a poll loop is the only thing keeping
    /// this current.
    private static let pollInterval: Duration = .seconds(1)
    /// The Streaming section's `viewModel.refreshStreamingSession()` is a
    /// network round-trip to `/Sessions`, unlike everything else here, and a
    /// transcode's parameters don't change every second. Refreshed on the first
    /// tick so the section isn't blank, then every
    /// `streamingSessionPollTicks`th.
    private static let streamingSessionPollTicks = 5
    private static let screenSize = UIScreen.main.bounds.size
    private static let refreshRateHz = UIScreen.main.maximumFramesPerSecond

    /// "1.0 (1)" — `CFBundleShortVersionString` plus build number, the pairing
    /// Settings and the App Store show.
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }()

    /// `AetherEngineVersion.current` is a checked-in generated constant, not a
    /// hand-maintained literal — see `Scripts/update-aetherengine-version.sh`.
    private static let aetherEngineVersion = AetherEngineVersion.current

    /// Hardware identifier (e.g. "iPhone15,1"), not the marketing name: it
    /// maps 1:1 to a chip/display/decoder combination. `uname`'s `machine`
    /// field is the only way to read it; there's no public UIKit API.
    private static let deviceModelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }()

    private static let iOSVersion = UIDevice.current.systemVersion

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
            if stats != nil, Self.pageCount > 1 {
                pageIndicator
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        // The box's tap target. The surrounding padding/frame has no
        // fill or contentShape, so SwiftUI never hit-tests it — taps pass
        // through to the video surface with no `.allowsHitTesting(false)`.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { advancePage() }
        // Page-advance as a named custom action for VoiceOver.
        // `children: .contain` (the default) keeps every row independently
        // readable rather than collapsing them into one label.
        .accessibilityAction(named: Text("Next Page")) { advancePage() }
        // Only while there's something to page through — matches
        // `pageIndicator`'s `stats != nil` gate above.
        .allowsHitTesting(isVisible && stats != nil && Self.pageCount > 1)
        .padding(.top, 56)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Not `.ignoresSafeArea()`, unlike the video surface and gradients:
        // the notch/Dynamic Island edge swaps between Landscape Left and
        // Right, and laying out inside the safe area clears it in both
        // without a per-orientation inset.
        .opacity(isVisible ? 1 : 0)
        // `.task(id: isVisible)`, not a bare `.task`: this view is mounted
        // permanently, so a bare `.task` starts once with `isVisible`
        // captured as `false` and a loop reading it inside that closure
        // sees that frozen value forever — the panel stayed on
        // "Gathering stats…" however often it was toggled. Keying on it
        // makes SwiftUI restart the task on every flip.
        .task(id: isVisible) { await pollWhileVisible() }
        // The next reopen starts on page 1 rather than wherever it was left.
        .onChange(of: isVisible) { _, visible in
            if !visible { currentPage = 0 }
        }
    }

    private var pageIndicator: some View {
        Text("\(currentPage + 1)/\(Self.pageCount)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
    }

    private func advancePage() {
        currentPage = (currentPage + 1) % Self.pageCount
    }

    private func pollWhileVisible() async {
        guard isVisible else { return }
        var tick = 0
        while !Task.isCancelled {
            stats = viewModel.stats
            audioOutputRoute = Self.currentAudioOutputRoute()
            audioOutputChannelCount = AVAudioSession.sharedInstance().outputNumberOfChannels
            thermalState = ProcessInfo.processInfo.thermalState
            edrHeadroom = UIScreen.main.currentEDRHeadroom
            if tick % Self.streamingSessionPollTicks == 0 {
                await viewModel.refreshServerVersion()
                await viewModel.refreshStreamingSession()
            }
            tick += 1
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Page 1: "what's playing" — the media and where it's up to. Page 2:
    /// "device/server" — the display/host and diagnostics that don't change
    /// moment to moment.
    ///
    /// Every page mounts, the inactive ones at `.opacity(0)`: a `ZStack` sizes
    /// itself to its largest child per dimension, so keeping them all in the
    /// tree makes the box's size the union of every page. Without it the box
    /// grew, shrank and (anchored `.topTrailing`) shifted as the pages' row
    /// counts came and went. This is plain `ZStack` sizing, not a
    /// `GeometryReader` measurement, so it can't hit the zero-size failure
    /// `PlayerControlsOverlay.estimatedHeight(for:)` describes.
    @ViewBuilder
    private var content: some View {
        if let stats {
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.pageCount, id: \.self) { page in
                    if page != currentPage {
                        pageContent(page, stats)
                            .opacity(0)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                pageContent(currentPage, stats)
            }
        } else {
            Text("Gathering stats…")
        }
    }

    @ViewBuilder
    private func pageContent(_ page: Int, _ stats: PlaybackStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case 0:
                videoSection(stats)
                audioSection(stats)
                playbackSection(stats)
            default:
                displaySection(stats)
                streamingSection()
                buildSection()
            }
        }
    }

    @ViewBuilder
    private func videoSection(_ stats: PlaybackStats) -> some View {
        Text("Video").bold()
        // `stats.videoSize`/`.frameRate`/`.bitrate` come from AetherEngine's
        // source probe, which never runs on the `nativeRemoteHLS` bypass
        // route — so all three stay `nil` for the life of such a session, not
        // just at startup. Falls back to `viewModel.sourceVideoStream`,
        // Jellyfin's probe of the same file, describing the source; the
        // Streaming section's rows describe the transcode target.
        row("Resolution", stats.videoSize ?? Self.sourceResolutionText(viewModel.sourceVideoStream) ?? "—")
        row("Frame Rate", stats.frameRate ?? Self.sourceFrameRateText(viewModel.sourceVideoStream) ?? "—")
        row("Bitrate", stats.bitrate ?? Self.sourceBitrateText(viewModel.sourceVideoStream) ?? "—")
        row("Source Color", stats.sourceColorFormat)
        if stats.sourceColorFormat.hasPrefix("Dolby Vision") {
            row("Enhancement Layer", Self.describeEnhancementLayer(viewModel.sourceVideoStream?.videoRangeType))
        }
        // No fallback, unlike the rows above: which decoder AVPlayer picked
        // for a `nativeRemoteHLS` session isn't exposed by AetherEngine and
        // isn't something Jellyfin's probe can answer, so this stays "—".
        row("Decoder", stats.videoDecoder ?? "—")
        row("Backend", stats.backend)
        row("Route", stats.route)
    }

    /// "Source Channels" is the media's own layout ("5.1", "Atmos", ...);
    /// "Output Channels" is what the current route is configured for (2 for
    /// built-in speakers whatever the source, up to 8 over HDMI/AirPlay). Kept
    /// as separate rows because a 7.1 source plays over stereo speakers
    /// downmixed — the same split `videoSection`/`displaySection` draw between
    /// "Source Color" and "Displayed Color".
    @ViewBuilder
    private func audioSection(_ stats: PlaybackStats) -> some View {
        Text("Audio").bold().padding(.top, 4)
        // Stays "—" for the session, same reasoning as the video Decoder row.
        row("Decoder", stats.audioDecoder ?? "—")
        // Same probe-never-runs gap as the video section — falls back to
        // `viewModel.sourceAudioStream`, Jellyfin's probe of the first audio
        // track.
        row("Source Channels", stats.audioChannels ?? Self.sourceChannelsText(viewModel.sourceAudioStream) ?? "—")
        row("Output Route", audioOutputRoute ?? "—")
        row("Output Channels", Self.describeChannelCount(audioOutputChannelCount))
    }

    @ViewBuilder
    private func playbackSection(_ stats: PlaybackStats) -> some View {
        // Always page 1's third section, never its leading one, so the top
        // padding is unconditional.
        Text("Playback").bold().padding(.top, 4)
        row("State", Self.describe(viewModel.state))
        row("Position", "\(Self.formatTime(stats.currentTime)) / \(Self.formatTime(stats.duration))")
        row("Buffered", Self.describeBuffered(seconds: stats.bufferedSeconds, bytes: stats.bufferedBytes))
        row("Zoom", zoomMode == .fill ? "Fill" : "Fit")
    }

    @ViewBuilder
    private func displaySection(_ stats: PlaybackStats) -> some View {
        // Page 2's leading section — no top padding, matching `videoSection`.
        Text("Display").bold()
        row("Screen", "\(Int(Self.screenSize.width))×\(Int(Self.screenSize.height)) pt")
        row("Displayed Color", stats.displayColorFormat)
        row("Refresh Rate", "\(Self.refreshRateHz) Hz")
        row("EDR Headroom", String(format: "%.2fx", edrHeadroom))
        row("Thermal State", Self.describe(thermalState))
    }

    /// Server-side diagnostics: the server's version, its view of this
    /// session's play method, and while transcoding the transcode parameters.
    /// See `PlayerViewModel.serverVersion`/`.streamingSession` for why these
    /// are separate, slower-polled requests rather than `PlaybackStats`.
    ///
    /// For offline playback there's no live session — both refresh methods
    /// no-op, leaving those properties `nil` forever — so this collapses to a
    /// single "Download" play method row.
    @ViewBuilder
    private func streamingSection() -> some View {
        Text(viewModel.isOfflinePlayback ? "Playback Source" : "Streaming").bold().padding(.top, 4)
        if viewModel.isOfflinePlayback {
            row("Play Method", "Download")
        } else {
            row("Jellyfin Server", viewModel.serverVersion ?? "—")
            row("Play Method", Self.describePlayMethod(viewModel.streamingSession?.playState?.playMethod))
            if let transcoding = viewModel.streamingSession?.transcodingInfo {
                row("Transcode Video", transcoding.videoCodec ?? "—")
                row("Transcode Audio", transcoding.audioCodec ?? "—")
                row("Transcode Bitrate", transcoding.bitrate.map(Self.formatMbps) ?? "—")
                if let width = transcoding.width, let height = transcoding.height {
                    row("Transcode Size", "\(width)×\(height)")
                }
                row("Completion", transcoding.completionPercentage.map { String(format: "%.0f%%", $0) } ?? "—")
                if let reasons = transcoding.transcodeReasons, !reasons.isEmpty {
                    row("Reasons", reasons.joined(separator: ", "))
                }
            }
        }
    }

    /// Build/environment info, static for the life of the process, so it's read
    /// once into `static let`s rather than polled by `pollWhileVisible`.
    @ViewBuilder
    private func buildSection() -> some View {
        Text("Build").bold().padding(.top, 4)
        row("App Version", Self.appVersion)
        row("AetherEngine Version", Self.aetherEngineVersion)
        row("Device", Self.deviceModelIdentifier)
        row("iOS Version", Self.iOSVersion)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
        }
    }

    private static func currentAudioOutputRoute() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }

    /// The "1.0"/"2.0"/"5.1"/"7.1" labeling `AetherPlaybackEngine
    /// .describeChannels` uses, applied to the device route's channel count so
    /// the two rows compare at a glance. No Atmos case:
    /// `AVAudioSession.outputNumberOfChannels` is a plain count with no way to
    /// tell whether an Atmos bed rides on it.
    private static func describeChannelCount(_ count: Int?) -> String {
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
    private static func describeBuffered(seconds: Double?, bytes: Int64?) -> String {
        guard let seconds else { return "N/A" }
        let secondsText = String(format: "%.1fs", seconds)
        guard let bytes else { return secondsText }
        return "\(secondsText) (\(formatKB(bytes)))"
    }

    private static func formatKB(_ bytes: Int64) -> String {
        "\((bytes / 1024).formatted()) KB"
    }

    /// `MediaStream.videoRangeType` is Jellyfin's server-side ffprobe result,
    /// the same value other clients surface. Only meaningful alongside a Dolby
    /// Vision `sourceColorFormat`: "DOVI" is a single-layer source with no base
    /// layer (DV Profile 5), the "DOVIWith..." cases name the format a non-DV
    /// panel falls back to.
    private static func describeEnhancementLayer(_ videoRangeType: String?) -> String {
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
    private static func describePlayMethod(_ raw: String?) -> String {
        guard let raw else { return "—" }
        switch raw {
        case "DirectPlay", "DirectStream": return "Direct Play"
        case "Transcode": return "Transcoding"
        default: return raw
        }
    }

    private static func formatMbps(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// Source-probe fallback for "Resolution" when AetherEngine's value is
    /// unavailable — see `videoSection`.
    private static func sourceResolutionText(_ stream: MediaStream?) -> String? {
        guard let stream, let width = stream.width, let height = stream.height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// Fallback for "Frame Rate". Prefers `realFrameRate` (measured from the
    /// file) over the coarser container-level `averageFrameRate`, like
    /// `MediaItem`'s technical-details formatting. `"%.3g fps"` matches
    /// `AetherPlaybackEngine.stats`, so the row reads the same whichever source
    /// populated it.
    private static func sourceFrameRateText(_ stream: MediaStream?) -> String? {
        guard let rate = stream?.realFrameRate ?? stream?.averageFrameRate, rate > 0 else { return nil }
        return String(format: "%.3g fps", rate)
    }

    /// Fallback for "Bitrate". The stream's own `MediaStream.bitRate`, not
    /// `MediaSourceInfo.bitrate`, which covers the whole container and is
    /// inflated by the file's audio tracks.
    private static func sourceBitrateText(_ stream: MediaStream?) -> String? {
        guard let bitRate = stream?.bitRate, bitRate > 0 else { return nil }
        return formatMbps(bitRate)
    }

    /// Fallback for "Source Channels". Jellyfin gives
    /// `audioSpatialFormat`/`channelLayout` rather than a numeric count, so no
    /// "1.0"/"5.1"/"7.1" normalization: its layout string is informative as-is.
    private static func sourceChannelsText(_ stream: MediaStream?) -> String? {
        guard let stream else { return nil }
        if stream.audioSpatialFormat == "DolbyAtmos" { return "Atmos" }
        return stream.channelLayout?.capitalized
    }

    private static func describe(_ state: PlaybackState) -> String {
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

    private static func describe(_ thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

let showPlaybackStatsButtonEnabledStorageKey = "showPlaybackStatsButtonEnabled"

/// On in debug builds, off in release. `PlayerControlsOverlay`'s `@AppStorage`
/// read of this key and `AdvancedPlaybackSettingsView`'s Toggle must declare
/// the same default to agree before the setting is ever visited — same
/// reasoning as `hero3DDepthEnabledStorageKey` in `HeroHeaderView.swift`.
#if DEBUG
let showPlaybackStatsButtonEnabledDefault = true
#else
let showPlaybackStatsButtonEnabledDefault = false
#endif
