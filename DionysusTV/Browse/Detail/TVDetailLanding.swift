import SwiftUI

enum TVDetailMetrics {
    /// The header's height on a page whose actions sit at its foot: at this
    /// height Play sits where tvOS wants a focused control, so the page opens
    /// at its true top. 60pt taller and tvOS nudged the page down on landing
    /// (measured frame by frame; see CLAUDE.md before changing it).
    static let headerHeight: CGFloat = 776
    /// How far a no-backdrop page's thumb sits below the header's top, so it
    /// clears the text beneath it (`tvDetailHeaderFrame(art:)`).
    static let landscapeArtTop: CGFloat = 40
}

extension View {
    /// Keeps a detail page's scroll view at its top while focus is in the
    /// header, and reports when focus has moved below it. Applied to the
    /// page's vertical `ScrollView`.
    ///
    /// In the header (the synopsis or the actions) the page sits at its
    /// start position: back from the rails it returns there, and focusing
    /// the synopsis doesn't scroll it higher. tvOS by itself scrolls only far
    /// enough to show the focused control, and its scroll can start after
    /// ours and win (seen from one row down, and again from three), so the
    /// page is also sent back whenever a scroll comes to rest anywhere else
    /// while focus is up here.
    func tvDetailLanding(focus: String?, isBelowHeader: Binding<Bool>, isBelow: @escaping (String) -> Bool) -> some View {
        modifier(TVDetailLanding(focus: focus, isBelowHeader: isBelowHeader, isBelow: isBelow))
    }
}

private struct TVDetailLanding: ViewModifier {
    let focus: String?
    @Binding var isBelowHeader: Bool
    let isBelow: (String) -> Bool
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// From the inset top, which is where `scrollTo(edge: .top)` goes: zero
    /// at the page's start position.
    @State private var scrollOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                scrollOffset = offset
            }
            .onChange(of: focus) { _, new in
                guard let new else { return }
                let below = isBelow(new)
                isBelowHeader = below
                if !below { restoreLanding() }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle, !isBelowHeader { restoreLanding() }
            }
    }

    private func restoreLanding() {
        guard abs(scrollOffset) > 1 else { return }
        withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
    }
}
