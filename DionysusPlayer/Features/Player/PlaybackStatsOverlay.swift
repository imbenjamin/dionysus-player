import SwiftUI

/// The landscape "stats for nerds" panel, toggled by the stats button in
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
/// size across a page tap. The size is the tallest page's, so a new row goes on
/// whichever page has room rather than on the one it reads best on.
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
    /// Readings from UIKit/AVFAudio rather than the playback engine, so
    /// they're polled here instead of via `PlaybackStats`.
    @State private var readings = PlaybackStatsReport.DeviceReadings()

    /// Which of `Self.pageCount` pages is showing — advanced by tapping the
    /// panel (`advancePage()`), looping past the last. Reset to `0` when the
    /// panel hides, so a reopen starts from the beginning.
    @State private var currentPage = 0
    /// Three fixed pages — Video; Audio and Playback; and "device/server"
    /// (Display/Streaming/Build) — rather than measuring available height at
    /// runtime. `GeometryReader` is avoided for the same reason as in
    /// `PlayerControlsOverlay.estimatedHeight(for:)`: the measured view renders
    /// at zero size. The cost is not adapting to how much content each page
    /// actually has. Video got a page to itself when AetherEngine 7.21.0's
    /// stream-format rows pushed Video/Audio/Playback past an iPhone's
    /// landscape height.
    private static let pageCount = 3

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
            .accessibilityIdentifier(A11yID.Player.statsPageIndicator)
    }

    private func advancePage() {
        currentPage = (currentPage + 1) % Self.pageCount
    }

    private func pollWhileVisible() async {
        guard isVisible else { return }
        var tick = 0
        while !Task.isCancelled {
            stats = viewModel.stats
            readings = .current()
            if tick % Self.streamingSessionPollTicks == 0 {
                await viewModel.refreshServerVersion()
                await viewModel.refreshStreamingSession()
            }
            tick += 1
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Page 1: the video stream. Page 2: the audio stream and where playback
    /// is up to. Page 3: "device/server" — the display/host and diagnostics
    /// that don't change moment to moment.
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

    /// Rows come from `PlaybackStatsReport`, which the Apple TV's panel shares.
    @ViewBuilder
    private func pageContent(_ page: Int, _ stats: PlaybackStats) -> some View {
        let sections: [PlaybackStatsReport.Section] = switch page {
        case 0: [PlaybackStatsReport.video(stats, sourceVideoStream: viewModel.sourceVideoStream)]
        case 1: [
            PlaybackStatsReport.audio(stats, sourceAudioStream: viewModel.sourceAudioStream, readings: readings),
            PlaybackStatsReport.playback(stats, state: viewModel.state, zoomMode: zoomMode)
        ]
        default: [
            PlaybackStatsReport.display(stats, readings: readings),
            PlaybackStatsReport.streaming(isOffline: viewModel.isOfflinePlayback, serverVersion: viewModel.serverVersion, session: viewModel.streamingSession),
            PlaybackStatsReport.build()
        ]
        }
        VStack(alignment: .leading, spacing: 2) {
            // A page's leading section has no top padding; the others do.
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Text(section.title).bold().padding(.top, index == 0 ? 0 : 4)
                ForEach(section.rows) { item in row(item.label, item.value, id: item.id) }
            }
        }
    }

    /// `id` keys the value's accessibility identifier where `label` alone
    /// isn't unique across pages (Video and Audio both have a "Decoder").
    private func row(_ label: String, _ value: String, id: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .accessibilityIdentifier(A11yID.Player.statsValue(id ?? label))
        }
    }
}
