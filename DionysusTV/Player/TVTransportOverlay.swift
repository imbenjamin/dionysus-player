import SwiftUI

/// The player's transport, drawn over the video. For now just the elapsed
/// time; the full transport (title, scrubber, format) follows.
struct TVTransportOverlay: View {
    let viewModel: PlayerViewModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text(Self.format(viewModel.currentTime))
                    .monospacedDigit()
                    .accessibilityIdentifier(A11yID.TV.Player.elapsed)
                Spacer()
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
    }

    private static func format(_ time: TimeInterval) -> String {
        let t = time.isFinite ? max(0, Int(time)) : 0
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
