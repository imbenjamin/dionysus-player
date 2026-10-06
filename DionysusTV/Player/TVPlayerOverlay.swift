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

            TVTransportOverlay(viewModel: viewModel, input: input)
            if let flash = input.state.flash {
                TVActionFlash(flash: flash)
            }
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
        .onPreferenceChange(BottomChromeTopKey.self) { top in
            MainActor.assumeIsolated { chromeTop = top }
        }
    }
}
