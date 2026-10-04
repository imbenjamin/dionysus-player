import SwiftUI

/// A "<" at the middle of the screen's left edge while the collapsed rail is
/// off screen (Search), saying the sidebar is that way: Menu, or Left from a
/// page's leftmost item, slides it in (Benjamin, 2026-10-04). It isn't
/// focusable and VoiceOver skips it; the sidebar's rows are what it reads.
struct TVEdgeChevron: View {
    var body: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityHidden(true)
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
