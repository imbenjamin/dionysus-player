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
/// with them while controls are showing.
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
///
/// All six sections no longer render as one screenful (they used to, split
/// into two columns in landscape) — a transcode session's Streaming
/// section alone can push the combined content taller than an iPhone's
/// landscape height, running the panel off the bottom of the screen and,
/// since it sits below `PlayerControlsOverlay` in this same `ZStack`,
/// visually colliding with the transport row too (confirmed live,
/// 2026-08-28). Content is now paginated (`currentPage`/`Self.pageCount`)
/// — only one page's worth of sections is *visible* at a time, cutting
/// the tallest case roughly in half. Every page still mounts, though (see
/// `content`'s own doc comment) — that's what keeps the box a constant
/// size across a page tap instead of resizing to match whichever page's
/// content happens to be showing.
/// Only the panel's own visible box is tappable to page through (see
/// `body`'s `.contentShape`/`.onTapGesture` on it): unlike the rest of this
/// view, that box deliberately does *not* stay `.allowsHitTesting(false)`,
/// so it needs its own explicit tap-target treatment rather than inheriting
/// this view's usual passthrough — a tap anywhere outside that box (on the
/// surrounding transparent frame, i.e. the actual video layer) still falls
/// straight through to `PlayerView`'s own show/hide-controls gesture on the
/// video surface underneath, same as before this existed.
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
    /// How many channels the device's *current audio route* is actually
    /// configured for — distinct from `stats.audioChannels` (the media's
    /// own channel layout); see `audioSection`'s doc comment.
    @State private var audioOutputChannelCount: Int?
    @State private var thermalState: ProcessInfo.ThermalState = .nominal
    /// How much extra brightness headroom the display currently has for
    /// HDR content above SDR white (1.0 = none, i.e. effectively SDR).
    /// Pairs with `PlaybackStats.displayColorFormat`: an HDR source
    /// reporting a headroom stuck at 1.0 means the panel isn't actually
    /// getting any HDR boost right now, whatever the format label says.
    @State private var edrHeadroom: CGFloat = 1

    /// Which of `Self.pageCount` pages is currently showing — advanced by
    /// tapping the panel itself (see `advancePage()`), looping back to `0`
    /// past the last one. Reset to `0` whenever the panel is hidden (see
    /// `body`'s `.onChange(of: isVisible)`) so reopening it always starts
    /// from the beginning rather than wherever it was last left.
    @State private var currentPage = 0
    /// Two fixed pages — "what's playing" (Video/Audio/Playback) and
    /// "device/server" (Display/Streaming/Build) — rather than anything
    /// that measures available height at runtime. A `GeometryReader`-based
    /// approach was deliberately avoided here for the same reason
    /// `PlayerControlsOverlay.estimatedHeight(for:)` avoids one for the
    /// track picker: every attempt there ended with the measured view
    /// rendering at zero size (see that function's own doc comment) —  a
    /// static split sidesteps that failure mode entirely, at the cost of
    /// not adapting to how much of each page's content is actually present
    /// (e.g. a direct-play session with a short Streaming section still
    /// pays for a full second page).
    private static let pageCount = 2

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

    /// `AetherEngineVersion.current` is a checked-in generated constant
    /// (`Scripts/update-aetherengine-version.sh`), not a hand-maintained
    /// literal — see that script's own comment for why it's a generated
    /// file rather than stamped in at build time.
    private static let aetherEngineVersion = AetherEngineVersion.current

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
        // The box's own tap target — everything *outside* it (the
        // surrounding padding/frame below) has no fill/contentShape of its
        // own, so SwiftUI never hit-tests that space at all (same "a
        // transparent area doesn't hit-test unless it's deliberately given
        // one" rule `PlayerControlsOverlay`'s blank-space catcher relies
        // on) — no explicit `.allowsHitTesting(false)` is needed there to
        // keep it passing taps through to the video surface underneath.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { advancePage() }
        // VoiceOver users get the same page-advance as a named custom
        // action rather than losing the panel's individual rows to a
        // combined single label — `children: .contain` (the default) keeps
        // every row independently readable, this just adds one more way to
        // reach `advancePage()` alongside the physical tap.
        .accessibilityAction(named: Text("Next Page")) { advancePage() }
        // Only while actually showing something to page through — matches
        // `pageIndicator`'s own `stats != nil` gate above.
        .allowsHitTesting(isVisible && stats != nil && Self.pageCount > 1)
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
        // Starts the next reopen back on page 1 rather than wherever it
        // was left — the same "fresh state on reopen" treatment as the
        // task above.
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

    /// Page 1: "what's playing" — the media itself and where it's up to.
    /// Page 2: "device/server" — the display/host and diagnostics that
    /// don't change moment to moment. Same grouping the two landscape
    /// columns used before pagination replaced them (see this type's own
    /// doc comment), just one page at a time now instead of side by side.
    ///
    /// Every other page mounts too, at `.opacity(0)` — a `ZStack` always
    /// sizes itself to its *largest* child in each dimension, so keeping
    /// every page's content in the tree (just invisible/non-interactive
    /// when it isn't the current one) makes the box's own reported size
    /// the union of every page rather than whichever one happens to be
    /// showing. That's what keeps the panel's width/height constant across
    /// a tap between pages — confirmed live, 2026-08-28, that without it
    /// the box visibly grew and shrank (and, anchored `.topTrailing`,
    /// shifted) as the two pages' very different row counts came and went.
    /// Plain `ZStack` sizing, not a measurement — no `GeometryReader`/
    /// `PreferenceKey` involved, so none of the "renders at zero size"
    /// failure `PlayerControlsOverlay.estimatedHeight(for:)`'s own doc
    /// comment describes trying and abandoning for a similar sizing
    /// problem can happen here.
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
        // own source probe — confirmed live, 2026-08-28, that probe never
        // runs on the `nativeRemoteHLS` bypass route (a server-chosen
        // "Allow Transcoding" session with no direct play), so all three
        // sit `nil` for the life of such a session, not just briefly at
        // startup. Falling back to `viewModel.sourceVideoStream` — Jellyfin's
        // own probe of the same file — keeps this row informative instead
        // of a permanent "—"; it describes the *source*, same as the
        // Streaming section's "Transcode Video"/"Transcode Bitrate" rows
        // already describe the transcode target, so the two together still
        // tell the full story.
        row("Resolution", stats.videoSize ?? Self.sourceResolutionText(viewModel.sourceVideoStream) ?? "—")
        row("Frame Rate", stats.frameRate ?? Self.sourceFrameRateText(viewModel.sourceVideoStream) ?? "—")
        row("Bitrate", stats.bitrate ?? Self.sourceBitrateText(viewModel.sourceVideoStream) ?? "—")
        row("Source Color", stats.sourceColorFormat)
        if stats.sourceColorFormat.hasPrefix("Dolby Vision") {
            row("Enhancement Layer", Self.describeEnhancementLayer(viewModel.sourceVideoStream?.videoRangeType))
        }
        // No fallback here, unlike the three rows above: which decoder
        // AVPlayer picked for a `nativeRemoteHLS` session isn't something
        // Jellyfin's probe (or anything else this app has) can answer —
        // AetherEngine itself doesn't expose it for this route, so this
        // stays "—" for the life of such a session.
        row("Decoder", stats.videoDecoder ?? "—")
        row("Backend", stats.backend)
        row("Route", stats.route)
    }

    /// "Source Channels" (the media's own channel layout — "5.1", "Atmos",
    /// ...) and "Output Channels" (how many channels the device's *current
    /// route* is actually configured for — 2 for the built-in speakers no
    /// matter the source, up to 8 over HDMI/AirPlay to a receiver) used to
    /// be one combined "Output" row, reading the source's channel count as
    /// if it were what's actually coming out of the speakers. They're
    /// different questions — a 7.1 source plays out over built-in stereo
    /// speakers just fine, downmixed, and this used to imply otherwise —
    /// same "Source Color" vs. "Displayed Color" split `videoSection`/
    /// `displaySection` already draw for video.
    @ViewBuilder
    private func audioSection(_ stats: PlaybackStats) -> some View {
        Text("Audio").bold().padding(.top, 4)
        // Same "—" for the life of the session, same reasoning as the
        // video Decoder row above.
        row("Decoder", stats.audioDecoder ?? "—")
        // Same probe-never-runs gap as the video section above — falls
        // back to `viewModel.sourceAudioStream` (Jellyfin's own probe of
        // the default/first audio track) rather than staying blank.
        row("Source Channels", stats.audioChannels ?? Self.sourceChannelsText(viewModel.sourceAudioStream) ?? "—")
        row("Output Route", audioOutputRoute ?? "—")
        row("Output Channels", Self.describeChannelCount(audioOutputChannelCount))
    }

    @ViewBuilder
    private func playbackSection(_ stats: PlaybackStats) -> some View {
        // Always page 1's third (never leading) section now that pagination
        // has replaced the old landscape/portrait branch this used to key
        // its top padding on — no longer conditional.
        Text("Playback").bold().padding(.top, 4)
        row("State", Self.describe(viewModel.state))
        row("Position", "\(Self.formatTime(stats.currentTime)) / \(Self.formatTime(stats.duration))")
        row("Buffered", Self.describeBuffered(seconds: stats.bufferedSeconds, bytes: stats.bufferedBytes))
        row("Zoom", zoomMode == .fill ? "Fill" : "Fit")
    }

    @ViewBuilder
    private func displaySection(_ stats: PlaybackStats) -> some View {
        // Page 2's leading section — no top padding, matching `videoSection`
        // (page 1's own leading section) just above it in this file.
        Text("Display").bold()
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
    /// `PlaybackStats`. For an offline download (`viewModel.isOfflinePlayback`),
    /// none of that applies — there's no live server session to report on
    /// (`refreshServerVersion()`/`refreshStreamingSession()` both no-op in
    /// that case, so `serverVersion`/`streamingSession` would just sit
    /// `nil` forever) — so this collapses to a single "Download" play
    /// method instead of a Jellyfin Server row and a blank/"—" one.
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

    /// Same "1.0"/"2.0"/"5.1"/"7.1" labeling `AetherPlaybackEngine
    /// .describeChannels` uses for the media's own channel count, applied
    /// here to the device route's actual channel count instead — same
    /// visual shape for both rows makes them easy to compare at a glance.
    /// No Atmos case (unlike that one): `AVAudioSession
    /// .outputNumberOfChannels` reports a plain channel count, with no way
    /// to know whether an Atmos bed is riding along on it.
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

    /// See `videoSection`'s doc comment — the source-probe fallback for
    /// "Resolution" when AetherEngine's own value is unavailable.
    private static func sourceResolutionText(_ stream: MediaStream?) -> String? {
        guard let stream, let width = stream.width, let height = stream.height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// Same fallback role as `sourceResolutionText` above, for "Frame
    /// Rate" — `realFrameRate` (measured from the file) preferred over
    /// `averageFrameRate` (a coarser, container-level figure), same
    /// preference `MediaItem`'s own technical-details formatting uses.
    /// `"%.3g fps"` matches `AetherPlaybackEngine.stats`'s own formatting
    /// for the same field, so the row reads identically regardless of
    /// which source populated it.
    private static func sourceFrameRateText(_ stream: MediaStream?) -> String? {
        guard let rate = stream?.realFrameRate ?? stream?.averageFrameRate, rate > 0 else { return nil }
        return String(format: "%.3g fps", rate)
    }

    /// Same fallback role, for "Bitrate" — the stream's own bit rate
    /// (`MediaStream.bitRate`), not `MediaSourceInfo.bitrate` (covers the
    /// whole container, inflated by however many audio tracks the file
    /// carries).
    private static func sourceBitrateText(_ stream: MediaStream?) -> String? {
        guard let bitRate = stream?.bitRate, bitRate > 0 else { return nil }
        return formatMbps(bitRate)
    }

    /// Same fallback role, for "Source Channels" — Jellyfin's own
    /// `audioSpatialFormat`/`channelLayout` rather than a numeric channel
    /// count (unlike `AetherPlaybackEngine.describeChannels`, which has one
    /// to work with), so this doesn't attempt the same "1.0"/"5.1"/"7.1"
    /// normalization — Jellyfin's own layout string ("Stereo", "5.1", ...)
    /// is informative as-is.
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
