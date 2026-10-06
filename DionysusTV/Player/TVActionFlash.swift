import SwiftUI

/// The glyph flashed mid-screen to confirm play, pause or a 10s skip, as
/// the native player does (Benjamin, 2026-10-06). Each action has a new
/// serial, so a repeat flashes again; it fades on its own.
struct TVActionFlash: View {
    let flash: TVPlayerInputState.Flash

    @State private var isVisible = false

    private static let shown: Duration = .milliseconds(700)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 64, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 160, height: 160)
            .glassEffect(.regular, in: Circle())
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.9)
            .animation(.easeOut(duration: 0.2), value: isVisible)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier(A11yID.TV.Player.actionFlash)
            .task(id: flash.serial) {
                isVisible = true
                try? await Task.sleep(for: Self.shown)
                guard !Task.isCancelled else { return }
                isVisible = false
            }
    }

    private var symbol: String {
        switch flash.kind {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .skipBack: "gobackward.10"
        case .skipForward: "goforward.10"
        }
    }

    private var label: String {
        switch flash.kind {
        case .play: String(localized: "Play")
        case .pause: String(localized: "Pause")
        case .skipBack: String(localized: "Back 10 seconds")
        case .skipForward: String(localized: "Forward 10 seconds")
        }
    }
}
