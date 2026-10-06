import SwiftUI

/// Everything drawn over the video, bottom to top. Takes no interaction:
/// the host's recognizers take every press (`TVPlayerInputModel`).
struct TVPlayerOverlay: View {
    let viewModel: PlayerViewModel
    let input: TVPlayerInput

    var body: some View {
        ZStack {
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
    }
}
