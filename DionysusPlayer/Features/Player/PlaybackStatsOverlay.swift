import SwiftUI
import UIKit
import AVFAudio

/// The landscape "stats for nerds" panel — toggled by the info button in
/// `PlayerControlsOverlay`'s top-right button group, and deliberately its
/// own layer sitting between the video surface and `PlayerControlsOverlay`
/// in `PlayerView`'s `ZStack` (see that view's body for the ordering), not
/// folded into the controls overlay itself. It stays visible through the
/// controls' own auto-hide fade — it isn't driven by `showControls` at all,
/// only by `isVisible` (`PlayerView`'s `showPlaybackStats`), a separate
/// toggle that only the info button flips.
///
/// Anchored top-trailing rather than top-leading: the logo/title
/// (`PlayerControlsOverlay.titleRow`) and close button own the top-leading
/// corner, so top-trailing is the corner least likely to visually collide
/// with them while controls are showing. In landscape, content splits into
/// two columns rather than one tall list — a single column ran tall enough
/// to reach down into the scrubber's own row on a phone's limited
/// landscape height.
///
/// Always mounted by `PlayerView`, with `isVisible` driving `.opacity`
/// rather than the view being conditionally inserted/removed — this view's
/// own `.frame(maxWidth: .infinity, maxHeight: .infinity)` is identical
/// whether or not it has anything to show, so toggling only its opacity
/// never changes what the enclosing `ZStack` reports as its own size.
/// Conditionally mounting it (the first version of this feature did) is
/// what caused the video layer and rest of the player UI to visibly shift
/// on every toggle: inserting/removing a sibling forces the whole `ZStack`
/// through a fresh layout pass, and `AetherPlayerSurface`'s bridged
/// `AVPlayerLayer`/`AVSampleBufferDisplayLayer` briefly re-lays-out along
/// with it.
struct PlaybackStatsOverlay: View {
    let viewModel: PlayerViewModel
    /// `PlayerView`'s own zoom-mode state — passed in rather than read off
    /// `viewModel`/the engine because it's view-local UI state, the same
    /// reason `PlayerView` mirrors it in the first place (see that
    /// property's doc comment).
    let zoomMode: VideoZoomMode
    let isVisible: Bool

    @State private var stats: PlaybackStats?
    /// The three device-level readings below aren't part of
    /// `PlaybackStats` — they come from UIKit/AVFAudio, not the playback
    /// engine, so they're polled here directly rather than routed through
    /// `PlaybackEngine`.
    @State private var audioOutputRoute: String?
    @State private var thermalState: ProcessInfo.ThermalState = .nominal
    /// How much extra brightness headroom the display currently has for
    /// HDR content above SDR white (1.0 = none, i.e. effectively SDR).
    /// Pairs with `PlaybackStats.displayColorFormat`: an HDR source
    /// reporting a headroom stuck at 1.0 means the panel isn't actually
    /// getting any HDR boost right now, whatever the format label says.
    @State private var edrHeadroom: CGFloat = 1

    /// `.compact` is iPhone's landscape signal — same check/caveat as
    /// `PlayerView.isLandscape` (see that property's doc comment).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Slow relative to the ~10 Hz playback clock — none of these numbers
    /// (bitrate, decoder, buffer depth, thermal state) meaningfully change
    /// faster than this, and polling less often keeps a purely diagnostic
    /// overlay from adding its own busywork to a screen that's often
    /// already decode-bound. `PlaybackEngine.stats` is a live snapshot read
    /// fresh on every call (see its doc comment) — nothing pushes updates,
    /// so a poll loop is what keeps this on screen current at all.
    private static let pollInterval: Duration = .seconds(1)
    /// The Streaming section's `viewModel.refreshStreamingSession()` is a
    /// network round-trip to `/Sessions`, not a local read like everything
    /// else this polls — and a transcode's live parameters don't change
    /// fast enough to justify hitting that every second anyway. Refreshed
    /// on the first tick (so the section doesn't sit blank) and every
    /// `streamingSessionPollTicks`th tick after that.
    private static let streamingSessionPollTicks = 5
    private static let screenSize = UIScreen.main.bounds.size
    private static let refreshRateHz = UIScreen.main.maximumFramesPerSecond

    /// "1.0 (1)" — `CFBundleShortVersionString` (`" (…)"` build number),
    /// same pairing Settings/App Store show for any app.
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }()

    /// AetherEngine exposes no runtime version API of its own (checked —
    /// nothing on `AetherEngine` reports it), so this mirrors the version
    /// pinned in `project.yml`/`Package.resolved` by hand. Keep it in sync
    /// when bumping the dependency.
    private static let aetherEngineVersion = "6.5.5"

    /// Hardware identifier (e.g. "iPhone15,1"), not the marketing name —
    /// more useful for diagnostics since it's what maps 1:1 to a specific
    /// chip/display/decoder combination. `uname`'s `machine` field is the
    /// standard way to read it; there's no public UIKit API for it.
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
        content
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 56)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // Deliberately *not* `.ignoresSafeArea()` — unlike the video
            // surface/gradients elsewhere in the player, this panel needs
            // to stay clear of whichever edge the notch/Dynamic
            // Island/sensor housing lands on, and that edge moves between
            // Landscape Left and Landscape Right. Laying out inside the
            // safe area (same as `PlayerControlsOverlay`'s own button row)
            // is what keeps it clear automatically across every
            // orientation, rather than a fixed inset guessed for one
            // orientation that then cuts into the notch in the other.
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            // `.task(id: isVisible)`, not a bare `.task` — a bare `.task`
            // only ever starts once for this view's whole (now permanent,
            // per the type's doc comment) lifetime, capturing whatever
            // `isVisible` was at that first launch, which is `false` the
            // very first time this ever renders. A loop built around
            // checking `isVisible` inside that closure was checking that
            // one frozen `false` forever — never actually re-reading the
            // live value on later toggles — which is what left the panel
            // stuck on "Gathering stats…" no matter how many times it was
            // switched on. Keying on `isVisible` makes SwiftUI cancel and
            // restart the task fresh every time it flips, so each run
            // starts with the current value rather than a stale one.
            .task(id: isVisible) { await pollWhileVisible() }
    }

    private func pollWhileVisible() async {
        guard isVisible else { return }
        var tick = 0
        while !Task.isCancelled {
            stats = viewModel.stats
            audioOutputRoute = Self.currentAudioOutputRoute()
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

    @ViewBuilder
    private var content: some View {
        if let stats {
            if isLandscape {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        videoSection(stats)
                        audioSection(stats)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        playbackSection(stats)
                        displaySection(stats)
                        streamingSection()
                        buildSection()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    videoSection(stats)
                    audioSection(stats)
                    playbackSection(stats)
                    displaySection(stats)
                    streamingSection()
                    buildSection()
                }
            }
        } else {
            Text("Gathering stats…")
        }
    }

    @ViewBuilder
    private func videoSection(_ stats: PlaybackStats) -> some View {
        Text("Video").bold()
        row("Resolution", stats.videoSize ?? "—")
        row("Frame Rate", stats.frameRate ?? "—")
        row("Bitrate", stats.bitrate ?? "—")
        row("Source Color", stats.sourceColorFormat)
        if stats.sourceColorFormat.hasPrefix("Dolby Vision") {
            row("Enhancement Layer", Self.describeEnhancementLayer(viewModel.sourceVideoStream?.videoRangeType))
        }
        row("Decoder", stats.videoDecoder ?? "—")
        row("Backend", stats.backend)
    }

    @ViewBuilder
    private func audioSection(_ stats: PlaybackStats) -> some View {
        Text("Audio").bold().padding(.top, 4)
        row("Decoder", stats.audioDecoder ?? "—")
        row("Output", Self.describeOutput(route: audioOutputRoute, channels: stats.audioChannels))
    }

    @ViewBuilder
    private func playbackSection(_ stats: PlaybackStats) -> some View {
        Text("Playback").bold().padding(.top, isLandscape ? 0 : 4)
        row("State", Self.describe(viewModel.state))
        row("Position", "\(Self.formatTime(stats.currentTime)) / \(Self.formatTime(stats.duration))")
        row("Buffered", Self.describeBuffered(seconds: stats.bufferedSeconds, bytes: stats.bufferedBytes))
        row("Zoom", zoomMode == .fill ? "Fill" : "Fit")
    }

    @ViewBuilder
    private func displaySection(_ stats: PlaybackStats) -> some View {
        Text("Display").bold().padding(.top, 4)
        row("Screen", "\(Int(Self.screenSize.width))×\(Int(Self.screenSize.height)) pt")
        row("Displayed Color", stats.displayColorFormat)
        row("Refresh Rate", "\(Self.refreshRateHz) Hz")
        row("EDR Headroom", String(format: "%.2fx", edrHeadroom))
        row("Thermal State", Self.describe(thermalState))
    }

    /// Jellyfin-server-side diagnostics — the server's own version, and its
    /// live view of this session's play method (and, only while actually
    /// transcoding, the transcode's current parameters). See
    /// `PlayerViewModel.serverVersion`/`.streamingSession`'s doc comments
    /// for why these come from separate, slower-polled requests rather than
    /// `PlaybackStats`.
    @ViewBuilder
    private func streamingSection() -> some View {
        Text("Streaming").bold().padding(.top, 4)
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

    /// Build/environment info — static for the life of the process, unlike
    /// every other section here, so it's read once into `static let`s below
    /// rather than polled on `pollWhileVisible`'s 1s loop.
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

    /// Route and channel layout are two different questions (where the
    /// sound is going vs. how many channels are in it) but read as one
    /// sentence — "Speaker (5.1)" — rather than two separate rows.
    private static func describeOutput(route: String?, channels: String?) -> String {
        switch (route, channels) {
        case let (route?, channels?): return "\(route) (\(channels))"
        case let (route?, nil): return route
        case let (nil, channels?): return channels
        case (nil, nil): return "—"
        }
    }

    /// `seconds` is the gate: `bytes` only ever accompanies it (both come
    /// from the same native-only source — see `PlaybackStats.bufferedBytes`'s
    /// doc comment) but is handled defensively in case the byte reading
    /// lags a tick behind on session startup.
    private static func describeBuffered(seconds: Double?, bytes: Int64?) -> String {
        guard let seconds else { return "N/A" }
        let secondsText = String(format: "%.1fs", seconds)
        guard let bytes else { return secondsText }
        return "\(secondsText) (\(formatKB(bytes)))"
    }

    private static func formatKB(_ bytes: Int64) -> String {
        "\((bytes / 1024).formatted()) KB"
    }

    /// `MediaStream.videoRangeType` is Jellyfin's own server-side probe
    /// result (ffprobe under the hood) — the same value other clients (and
    /// Jellyfin Web's own technical-info panel) surface. Only meaningful
    /// alongside a Dolby Vision `sourceColorFormat`; the "DOVI" case is a
    /// single-layer source with no base layer at all (DV Profile 5), the
    /// "DOVIWith..." cases name whichever format a non-DV panel would fall
    /// back to.
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

    /// Jellyfin's own `PlayMethod` enum, as reported by `/Sessions` —
    /// `"DirectPlay"`/`"DirectStream"` both read as "Direct Play" here since
    /// neither transcodes (the distinction is server access mechanics, not
    /// anything this overlay's audience cares about); anything else
    /// (`"Transcode"`, or an unrecognized future value) passes through
    /// as-is rather than being silently mapped to the wrong label.
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

    private static func describe(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "Idle"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .seeking: return "Seeking"
        case .buffering: return "Buffering"
        case .ended: return "Ended"
        case .failed(let message): return "Failed (\(message))"
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
