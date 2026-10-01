import SwiftUI

extension View {
    /// Puts focus on a page's default item, as each signed-in page does
    /// itself: never with `.defaultFocus`, which on Profile pulled every
    /// later move back to its target.
    ///
    /// - When the items first arrive: the remembered one if it's still there
    ///   (back from the player, focus lands on what was played), otherwise the
    ///   first, unless the person has already moved or is in the sidebar.
    /// - On each handoff from the sidebar (`tvFocusHandoff`): the first item,
    ///   since choosing a page opens it at its start (Benjamin, 2026-10-01).
    ///
    /// `ids` are the page's focusable items in order; the first is its
    /// default. Whatever has focus is written to `remembered`.
    func tvClaimsFocus<ID: Hashable>(_ focus: FocusState<ID?>.Binding, ids: [ID], remembered: Binding<ID?>) -> some View {
        modifier(TVDefaultFocus(focus: focus, ids: ids, remembered: remembered))
    }
}

private struct TVDefaultFocus<ID: Hashable>: ViewModifier {
    let focus: FocusState<ID?>.Binding
    let ids: [ID]
    @Binding var remembered: ID?
    @State private var userMoved = false
    @Environment(\.tvFocusHandoff) private var handoff
    @Environment(\.tvSidebarExpanded) private var sidebarExpanded
    @Environment(\.tvPageClaimedFocus) private var claimed

    func body(content: Content) -> some View {
        content
            .onChange(of: ids.first, initial: true) { _, first in
                guard focus.wrappedValue == nil, let first else { return }
                if let remembered, ids.contains(remembered) {
                    claim(remembered)
                } else if !userMoved, !sidebarExpanded {
                    claim(first)
                }
            }
            .onChange(of: handoff) {
                if let first = ids.first { claim(first) }
            }
            .onChange(of: focus.wrappedValue) { _, id in
                if let id { remembered = id }
            }
            .onMoveCommand { _ in userMoved = true }
    }

    private func claim(_ id: ID) {
        focus.wrappedValue = id
        claimed()
    }
}
