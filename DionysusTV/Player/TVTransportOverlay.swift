import SwiftUI

/// The player's transport, drawn over the video: the title top-left, and at
/// the bottom a scrubber with chapter ticks, the times, and the format chip.
/// Shown while `chrome` says so, and always while paused or loading.
struct TVTransportOverlay: View {
    let viewModel: PlayerViewModel
    let chrome: TVTransportChrome

    @State private var isLogoFallbackVisible = false

    /// Off until AetherEngine reports HDR reliably on tvOS. EDR headroom reads
    /// 1.00 on an HDR10 panel there, so the engine only corrects its label once
    /// AVPlayer accepts the HDR master; a session that falls back to the media
    /// playlist still reads SDR, which would contradict the TV's own banner.
    static let showsFormatChip = false

    private var showsChrome: Bool {
        chrome.isVisible || viewModel.state == .paused || viewModel.state == .loading
    }

    var body: some View {
        ZStack {
            if viewModel.state == .loading {
                ProgressView().controlSize(.large)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .padding(30)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
            }
            if showsChrome {
                chromeLayer.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: showsChrome)
        .onChange(of: viewModel.state) { old, new in
            chrome.playbackStateChanged(from: old, to: new)
        }
    }

    private var chromeLayer: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 360)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 420)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                titleBlock
                Spacer()
                bottomBar
            }
            // No padding of its own: the safe area already insets it to the
            // HIG's 80pt sides and 60pt top and bottom.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var titleBlock: some View {
        if let item = viewModel.item {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    if let logo = item.logoImageURL {
                        #if DEBUG
                        LogoImageView(
                            url: logo, fallback: titleText(item.railTitle),
                            onFallbackVisibilityChange: { isLogoFallbackVisible = $0 }
                        )
                        .frame(maxWidth: 460, maxHeight: 110, alignment: .topLeading)
                        #else
                        LogoImageView(url: logo, fallback: titleText(item.railTitle))
                            .frame(maxWidth: 460, maxHeight: 110, alignment: .topLeading)
                        #endif
                    } else {
                        titleText(item.railTitle)
                    }
                    if item.kind == .episode {
                        Text(item.numberedEpisodeName)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                // `.ignore` plus an explicit label, as on iOS: a logo is an
                // unlabelled image, which would leave the block nameless.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityDescription)
                .accessibilityIdentifier(A11yID.TV.Player.titleBlock)

                #if DEBUG
                // Test-only, beside the collapsed block rather than inside it.
                if UITestConfiguration.isActive, isLogoFallbackVisible {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier(A11yID.Media.heroLogoFallbackVisible)
                }
                #endif
            }
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .lineLimit(2)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            scrubber
            HStack {
                Text(TVPlaybackTimeFormat.string(viewModel.currentTime))
                    .monospacedDigit()
                    .accessibilityIdentifier(A11yID.TV.Player.elapsed)
                Spacer()
                if Self.showsFormatChip, let format = viewModel.videoFormatDescription {
                    Text(format.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.35), in: .capsule)
                        .accessibilityIdentifier(A11yID.TV.Player.formatLabel)
                }
                Spacer()
                Text("\u{2212}" + TVPlaybackTimeFormat.string(max(0, viewModel.duration - viewModel.currentTime)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.semibold))
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let duration = viewModel.duration
            let fraction = duration > 0 ? min(1, max(0, viewModel.currentTime / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: geo.size.width * fraction)
                if duration > 0 {
                    ForEach(viewModel.chapters.filter { $0.startSeconds > 0 }) { chapter in
                        Rectangle()
                            .fill(.black.opacity(0.75))
                            .frame(width: 5)
                            .offset(x: geo.size.width * chapter.startSeconds / duration)
                    }
                }
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(TVPlaybackTimeFormat.string(viewModel.currentTime)))
        .accessibilityIdentifier(A11yID.TV.Player.transport)
    }
}
