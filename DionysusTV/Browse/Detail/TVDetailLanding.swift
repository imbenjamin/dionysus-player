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
    /// Each change of `topRequest` sends the page back to its top, as Home's
    /// Menu does from below the hero.
    func tvDetailLanding(
        focus: String?, isBelowHeader: Binding<Bool>, topRequest: Int = 0, isBelow: @escaping (String) -> Bool
    ) -> some View {
        modifier(TVDetailLanding(focus: focus, isBelowHeader: isBelowHeader, topRequest: topRequest, isBelow: isBelow))
    }
}

private struct TVDetailLanding: ViewModifier {
    let focus: String?
    @Binding var isBelowHeader: Bool
    let topRequest: Int
    let isBelow: (String) -> Bool
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// From the inset top, which is where `scrollTo(edge: .top)` goes: zero
    /// at the page's start position.
    @State private var scrollOffset: CGFloat = 0
    /// From when the page is covered until shortly after it's back on show.
    /// As it comes back tvOS focuses its first item (Play) before the page
    /// puts focus back on the item it had (`tvClaimsFocus`); taken at its
    /// word, that sent the page to its top and left the item it had, a
    /// Continue Watching tile, cut off at the screen's foot (Benjamin,
    /// 2026-10-07).
    @State private var settling = false
    @Environment(\.tvPageIsOnShow) private var isOnShow

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                scrollOffset = offset
            }
            .onChange(of: focus) { _, new in
                guard let new else { return }
                let below = isBelow(new)
                if settling, !below { return }
                isBelowHeader = below
                if !below { restoreLanding() }
            }
            .onChange(of: topRequest) { restoreLanding() }
            .onScrollPhaseChange { _, phase in
                if phase == .idle, !isBelowHeader, !settling { restoreLanding() }
            }
            .onChange(of: isOnShow) { _, onShow in
                guard onShow else {
                    settling = true
                    return
                }
                // Longer than the page's own claim, which is set until it
                // holds for up to half a second.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    settling = false
                }
            }
    }

    private func restoreLanding() {
        guard abs(scrollOffset) > 1 else { return }
        withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
    }
}
