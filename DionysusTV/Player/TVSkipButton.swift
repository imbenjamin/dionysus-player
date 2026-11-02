import SwiftUI

/// "Skip Intro" and the like, bottom-right (prototype screen 14). Focused
/// whenever Select would skip (`TVPlayerInputModel.selectSkips`).
struct TVSkipButton: View {
    let title: String
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Image(systemName: "forward.fill").accessibilityHidden(true)
        }
        // The swipe-down panel's button scale (Benjamin, 2026-10-07).
        .font(.callout.weight(.semibold))
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Capsule().fill(isFocused ? Color.white : Color.black.opacity(0.45)))
        .overlay(Capsule().stroke(Color.white.opacity(isFocused ? 0 : 0.4), lineWidth: 2))
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(A11yID.TV.Player.skipButton)
    }
}
