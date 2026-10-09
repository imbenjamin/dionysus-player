import SwiftUI

/// Everything drawn over the video, bottom to top. Takes no interaction:
/// the host's recognizers take every press (`TVPlayerInputModel`).
///
/// In the accessible transport (M5) the controls move to a layer presented
/// over the player (`TVAccessibleTransportLayer`), where the focus engine
/// can reach them; this overlay then draws the subtitles alone, so libass
/// never runs twice.
struct TVPlayerOverlay: View {
    enum Role { case player, accessibleLayer }

    let viewModel: PlayerViewModel
    let input: TVPlayerInput
    var role: Role = .player

    private var drawsSubtitles: Bool { role == .player }
    private var drawsControls: Bool { role == .accessibleLayer || !input.accessibleTransport }
    /// The top of the transport's bottom bar while it shows
    /// (`BottomChromeTopKey`), so cues sit above it. Kept on `input`, since
    /// the controls and the subtitles can be in different layers.
    private var chromeTop: CGFloat { input.chromeTop }

    var body: some View {
        ZStack {
            if drawsSubtitles {
                // Ignores the safe area to lie over the full-bleed picture; libass
                // reads the window's insets itself (CLAUDE.md, Subtitles).
                SubtitleOverlayView(
                    viewModel: viewModel, zoomMode: .fit,
                    controlsVisible: input.state.chrome == .transport,
                    controlsTop: chromeTop, metrics: .tv
                )
                .ignoresSafeArea()
            }
            if drawsControls {
                controls
            }
        }
        .modifier(AccessibleLayerCommands(isOn: role == .accessibleLayer, input: input))
        // Per-item view state (the thumbnail loader) starts fresh when Next
        // Up plays the next item in this player.
        .id(viewModel.itemID)
        // The accessible transport says when Skip or Next Up arrives (M5);
        // Next Up once, never each second of its countdown.
        .onChange(of: viewModel.currentSkipSegment?.id) { _, id in
            guard role == .accessibleLayer, id != nil, let segment = viewModel.currentSkipSegment else { return }
            AccessibilityNotification.Announcement(TVPlayerAnnouncement.skipAvailable(segment.kind.skipButtonTitle)).post()
        }
        .onChange(of: viewModel.nextUpSecondsRemaining != nil) { _, shows in
            guard role == .accessibleLayer, shows, let episode = viewModel.nextEpisode else { return }
            AccessibilityNotification.Announcement(TVPlayerAnnouncement.nextUp(episode.railTitle)).post()
        }
        .onPreferenceChange(BottomChromeTopKey.self) { top in
            // Only from the layer drawing the controls: the other reports
            // no chrome and would overwrite it.
            MainActor.assumeIsolated { if drawsControls { input.chromeTop = top } }
        }
    }

    @ViewBuilder
    private var controls: some View {
        // Inside the safe area, so it sits at the title-safe insets,
        // top-right, clear of the title block.
        if TVPlayerInputModel.statsPanelShows(input.state, context: input.snapshot()) {
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
                .accessibilityLabel(TVPlayerFocusID.describe(input.state, context: input.snapshot()))
                .accessibilityIdentifier(A11yID.TV.Player.focus)
        }
        #endif
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
            let context = input.snapshot()
            let lift = chromeTop.isFinite ? max(0, proxy.frame(in: .global).maxY - chromeTop + 30) : 0
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let episode = viewModel.nextEpisode, let seconds = viewModel.nextUpSecondsRemaining {
                        TVNextUpCard(
                            episode: episode, secondsRemaining: seconds,
                            totalSeconds: viewModel.nextUpTotalCountdownSeconds ?? seconds,
                            focus: TVPlayerInputModel.nextUpHasFocus(input.state, context: context) ? input.state.nextUpFocus : nil,
                            send: input.accessibleTransport ? { input.send(.control(.nextUp($0))) } : nil
                        )
                    } else if let segment = viewModel.currentSkipSegment,
                              TVPlayerInputModel.skipButtonVisible(input.state, context: context) {
                        if input.accessibleTransport {
                            TVPlayerControlButton(action: { input.send(.control(.skipSegment)) }) { focused in
                                TVSkipButton(title: segment.kind.skipButtonTitle, isFocused: focused)
                            }
                            .accessibilityIdentifier(A11yID.TV.Player.skipButton)
                        } else {
                            TVSkipButton(
                                title: segment.kind.skipButtonTitle,
                                isFocused: TVPlayerInputModel.selectSkips(input.state, context: context)
                            )
                        }
                    }
                }
            }
            .padding(.bottom, lift)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeTop)
    }
}

/// Menu and Play/Pause in the accessible transport's layer (M5), where
/// presses start at the focused control rather than the player's
/// recognizers. Menu left to UIKit dismissed the layer itself, leaving the
/// player with no controls.
private struct AccessibleLayerCommands: ViewModifier {
    let isOn: Bool
    let input: TVPlayerInput

    func body(content: Content) -> some View {
        if isOn {
            content
                .onExitCommand { input.send(.menu) }
                .onPlayPauseCommand { input.send(.playPause) }
        } else {
            content
        }
    }
}
