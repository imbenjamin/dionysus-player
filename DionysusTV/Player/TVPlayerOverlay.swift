import SwiftUI

/// Everything drawn over the video, bottom to top. Takes no interaction:
/// the host's recognizers take every press (`TVPlayerInputModel`).
struct TVPlayerOverlay: View {
    let viewModel: PlayerViewModel
    let input: TVPlayerInput

    /// The top of the transport's bottom bar while it shows
    /// (`BottomChromeTopKey`), so cues sit above it.
    @State private var chromeTop: CGFloat = .infinity

    var body: some View {
        ZStack {
            // Ignores the safe area to lie over the full-bleed picture; libass
            // reads the window's insets itself (CLAUDE.md, Subtitles).
            SubtitleOverlayView(
                viewModel: viewModel, zoomMode: .fit,
                controlsVisible: input.state.chrome == .transport,
                controlsTop: chromeTop, metrics: .tv
            )
            .ignoresSafeArea()

            // Inside the safe area, so it sits at the title-safe insets,
            // top-right, clear of the title block.
            if input.state.isStatsOn, input.context().statsButtonEnabled {
                TVStatsPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }

            TVTransportOverlay(viewModel: viewModel, input: input)
            // Centred on the whole screen, whatever else is drawn: inside the
            // safe area it sat higher than centre (Benjamin, 2026-10-06).
            Color.clear
                .overlay {
                    if let flash = input.state.flash {
                        TVActionFlash(flash: flash)
                    }
                }
                .ignoresSafeArea()
            bottomTrailing
            #if DEBUG
            if UITestConfiguration.isActive {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(TVPlayerFocusID.describe(input.state, context: input.context()))
                    .accessibilityIdentifier(A11yID.TV.Player.focus)
            }
            #endif
        }
        // Per-item view state (the thumbnail loader, `chromeTop`) starts
        // fresh when Next Up plays the next item in this player.
        .id(viewModel.itemID)
        .onPreferenceChange(BottomChromeTopKey.self) { top in
            MainActor.assumeIsolated { chromeTop = top }
        }
    }

    /// Skip and Next Up share the bottom-right slot; the view model makes
    /// them exclusive. With the transport up they sit above it; with the
    /// panel open they wait, since the panel fills the lower half.
    @ViewBuilder
    private var bottomTrailing: some View {
        if input.state.panel == nil {
            bottomTrailingSlot
        }
    }

    private var bottomTrailingSlot: some View {
        GeometryReader { proxy in
            let context = input.context()
            let lift = chromeTop.isFinite ? max(0, proxy.frame(in: .global).maxY - chromeTop + 30) : 0
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let episode = viewModel.nextEpisode, let seconds = viewModel.nextUpSecondsRemaining {
                        TVNextUpCard(
                            episode: episode, secondsRemaining: seconds,
                            totalSeconds: viewModel.nextUpTotalCountdownSeconds ?? seconds,
                            focus: TVPlayerInputModel.nextUpHasFocus(input.state, context: context) ? input.state.nextUpFocus : nil
                        )
                    } else if let segment = viewModel.currentSkipSegment,
                              TVPlayerInputModel.skipButtonVisible(input.state, context: context) {
                        TVSkipButton(
                            title: segment.kind.skipButtonTitle,
                            isFocused: TVPlayerInputModel.selectSkips(input.state, context: context)
                        )
                    }
                }
            }
            .padding(.bottom, lift)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeTop)
    }
}
