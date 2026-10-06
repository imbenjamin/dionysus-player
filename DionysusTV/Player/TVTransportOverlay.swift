import SwiftUI

/// The player's transport, drawn over the video: the title top-left, and at
/// the bottom a scrubber with chapter ticks, the times, and the format chip.
/// Shown while the input model's state says so (`TVPlayerInputModel`).
struct TVTransportOverlay: View {
    let viewModel: PlayerViewModel
    let input: TVPlayerInput

    @State private var isLogoFallbackVisible = false
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var chaptersInScrubber = chaptersInScrubberEnabledDefault
    @State private var bufferedSeconds: Double?
    @State private var thumbnails: TVScrubThumbnailLoader

    init(viewModel: PlayerViewModel, input: TVPlayerInput) {
        self.viewModel = viewModel
        self.input = input
        _thumbnails = State(initialValue: TVScrubThumbnailLoader(fetch: { [viewModel] seconds in
            await viewModel.scrubThumbnail(atSeconds: seconds)
        }))
    }

    private var state: TVPlayerInputState { input.state }
    private var showsChrome: Bool { state.chrome == .transport }
    /// The preview's time while scrubbing, else the playhead.
    private var shownTime: TimeInterval { state.scrub?.previewTime ?? viewModel.currentTime }

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
        // `PlaybackStats.bufferedSeconds` is polled, not pushed; once a
        // second is plenty for a fill nobody reads to the second.
        .task(id: showsChrome) {
            while showsChrome, !Task.isCancelled {
                bufferedSeconds = viewModel.stats.bufferedSeconds
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: state.scrub?.previewTime) { _, time in
            if let time { thumbnails.request(time) } else { thumbnails.reset() }
        }
    }

    private var chromeLayer: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 360)
                Spacer()
                // Deeper with the panel open, so its rows read over the
                // picture (prototype `PlayerTabs`). 360 + 720 fills the
                // 1080pt screen exactly: any taller and this layer outgrew the
                // screen and was centred, pushing the title off the top.
                LinearGradient(
                    colors: state.panel == nil
                        ? [.clear, .black.opacity(0.85)]
                        : [.clear, .black.opacity(0.75), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: state.panel == nil ? 420 : 720)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            // No padding of its own: the safe area already insets it to the
            // HIG's 80pt sides and 60pt top and bottom.
            if let panel = state.panel {
                // The panel lifts the scrubber to mid-screen, without its
                // icons, at the prototype's positions on the 1920×1080 screen
                // (screen 13: the title at 60, the scrubber at 440, the tabs
                // at 560, 80 in from each side). Laid out in screen
                // coordinates, since inside the safe area this layer started
                // at the screen's top edge (measured), and hung in an overlay
                // of a screen-sized view, so no child can grow the layer and
                // have it re-centred. The scrubber block reports
                // `BottomChromeTopKey`, so a subtitle just chosen shows above
                // it.
                Color.clear
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            titleBlock
                                .padding(.top, 60)
                            VStack(alignment: .leading, spacing: 18) {
                                scrubber
                                timesRow
                            }
                            .reportsBottomChromeTop()
                            .padding(.top, 440)
                            TVPlayerPanelView(viewModel: viewModel, panel: panel, tabs: TVPlayerInputModel.availableTabs(input.context()))
                                .padding(.top, 560)
                        }
                        .padding(.horizontal, 80)
                    }
                    .ignoresSafeArea()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    Spacer()
                    bottomBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            iconRow
            scrubber
            timesRow
        }
        // Built only while the chrome shows, so once it fades the key falls
        // back to `.infinity` and cues rest (`SubtitleOverlayView`).
        .reportsBottomChromeTop()
    }

    /// Elapsed, the format chip and remaining, under the scrubber.
    private var timesRow: some View {
        HStack {
            Text(TVPlaybackTimeFormat.string(shownTime))
                .monospacedDigit()
                .accessibilityIdentifier(A11yID.TV.Player.elapsed)
            Spacer()
            if let chip = TVTransportLayout.formatChipText(viewModel.videoFormatDescription) {
                Text(chip)
                    .font(.caption.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: .capsule)
                    .accessibilityIdentifier(A11yID.TV.Player.formatLabel)
            }
            Spacer()
            Text("\u{2212}" + TVPlaybackTimeFormat.string(max(0, viewModel.duration - shownTime)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.TV.Player.remaining)
        }
        .font(.callout.weight(.semibold))
    }

    private var iconRow: some View {
        HStack(spacing: 18) {
            Spacer()
            ForEach(input.context().availableIcons, id: \.self) { icon in
                TVPlayerIconButton(
                    icon: icon,
                    isFocused: state.transportFocus == .icon(icon),
                    isOn: icon == .stats && state.isStatsOn
                )
            }
        }
        .frame(height: 96)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let duration = viewModel.duration
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Every bar keeps the track's 12pt: the knob, 36pt, is in
                // the same stack and would otherwise stretch them.
                Capsule().fill(.white.opacity(0.25)).frame(height: 12)
                if let buffered = TVTransportLayout.bufferedFraction(
                    currentTime: viewModel.currentTime, bufferedSeconds: bufferedSeconds, duration: duration
                ) {
                    Capsule().fill(.white.opacity(0.45))
                        .frame(width: width * buffered, height: 12)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Buffered"))
                        .accessibilityIdentifier(A11yID.TV.Player.bufferedRange)
                }
                Capsule().fill(.white)
                    .frame(width: width * TVTransportLayout.fraction(viewModel.currentTime, duration: duration), height: 12)
                if chaptersInScrubber, duration > 0 {
                    ForEach(viewModel.chapters.filter { $0.startSeconds > 0 }) { chapter in
                        Rectangle()
                            .fill(.black.opacity(0.75))
                            .frame(width: 5, height: 12)
                            .offset(x: width * chapter.startSeconds / duration)
                    }
                }
                if let scrub = state.scrub {
                    let fraction = TVTransportLayout.fraction(scrub.previewTime, duration: duration)
                    knob(at: fraction, width: width)
                    TVScrubPreview(
                        image: thumbnails.image,
                        showsFrame: viewModel.supportsScrubThumbnails,
                        caption: TVTransportLayout.previewCaption(
                            time: scrub.previewTime, chapterName: viewModel.chapters.chapter(at: scrub.previewTime)?.name
                        ),
                        scanLevel: scrub.scan?.level
                    )
                    .fixedSize()
                    .position(
                        x: TVTransportLayout.previewCenterX(fraction: fraction, trackWidth: width, previewWidth: TVScrubPreview.size.width),
                        y: -(TVScrubPreview.size.height / 2 + 150)
                    )
                } else if TVPlayerInputModel.scrubberHasFocus(state), duration > 0 {
                    // The scrubber's focus (Benjamin, 2026-10-06): a knob at
                    // the playhead whenever the scrubber has it.
                    knob(at: TVTransportLayout.fraction(viewModel.currentTime, duration: duration), width: width)
                }
            }
            // Pinned to the track, so the knob overflows it rather than
            // growing the stack and moving the bar down.
            .frame(width: width, height: 12)
        }
        .frame(height: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(TVPlaybackTimeFormat.string(shownTime)))
        .accessibilityIdentifier(A11yID.TV.Player.transport)
    }

    private func knob(at fraction: Double, width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 36, height: 36)
            .shadow(color: .black.opacity(0.5), radius: 10)
            .offset(x: width * fraction - 18)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// Publishes this view's top edge as `BottomChromeTopKey`, so subtitles
    /// sit above it.
    func reportsBottomChromeTop() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: BottomChromeTopKey.self, value: proxy.frame(in: .global).minY)
            }
        )
    }
}
