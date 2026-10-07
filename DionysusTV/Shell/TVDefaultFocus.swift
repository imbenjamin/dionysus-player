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
    /// - When the page comes back on show after the page above it is popped
    ///   (`tvPageIsOnShow`): the remembered item. A hidden page claims nothing.
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
    /// Direction presses on the page, so a claim stops at the first one.
    @State private var moves = 0
    /// The item to put focus back on while the page is covered, and until
    /// it has it again.
    @State private var restoring: ID?
    /// What had focus when the sidebar opened. `remembered` can't be used on
    /// the way back: tvOS's own move into the page lands first and is
    /// remembered before the return is handled.
    @State private var beforeRail: ID?
    @Environment(\.tvFocusHandoff) private var handoff
    @Environment(\.tvRailReturn) private var railReturn
    @Environment(\.tvSidebarExpanded) private var sidebarExpanded
    @Environment(\.tvPageClaimedFocus) private var claimed
    @Environment(\.tvPageClaimingFocus) private var claiming
    @Environment(\.tvPageIsOnShow) private var isOnShow

    func body(content: Content) -> some View {
        content
            .onChange(of: ids.first, initial: true) { _, first in
                guard isOnShow, focus.wrappedValue == nil, let first else { return }
                if let remembered, ids.contains(remembered) {
                    claim(remembered)
                } else if !userMoved, !sidebarExpanded {
                    claim(first)
                }
            }
            // Right out of the sidebar: back to the item the page last had,
            // set until it holds, since tvOS's own move lands first.
            .onChange(of: sidebarExpanded) { _, expanded in
                if expanded { beforeRail = remembered }
            }
            .onChange(of: railReturn) {
                guard isOnShow, let target = beforeRail, ids.contains(target) else { return }
                Task { @MainActor in
                    for _ in 0..<10 {
                        if focus.wrappedValue == target { return }
                        focus.wrappedValue = target
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
            }
            .onChange(of: handoff) {
                guard isOnShow, let first = ids.first else { return }
                claim(first)
            }
            // Back on show after the page above was popped: focus returns to
            // where it was. The page was never torn down, so the item is
            // built, lazy container or not. tvOS puts focus on the page's
            // first item as the page is enabled again, and a claim made in
            // the same pass is dropped, so the target is fixed when the page
            // is covered and claimed until it holds.
            .onChange(of: isOnShow) { _, onShow in
                guard onShow else {
                    restoring = remembered
                    return
                }
                guard let target = restoring.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else {
                    restoring = nil
                    return
                }
                restoring = target
                Task { @MainActor in
                    for _ in 0..<10 {
                        focus.wrappedValue = target
                        try? await Task.sleep(for: .milliseconds(50))
                        if focus.wrappedValue == target { break }
                    }
                    restoring = nil
                    remembered = target
                    claimed()
                }
            }
            .onChange(of: focus.wrappedValue) { _, id in
                dbgLog.notice("page focus -> \(String(describing: id), privacy: .public) onShow=\(isOnShow)")
                if let id, isOnShow, restoring == nil { remembered = id }
            }
            .onMoveCommand { d in
                dbgLog.notice("move \(String(describing: d), privacy: .public)")
                userMoved = true
                moves += 1
            }
    }

    /// Holds the rail until focus is on `id`, then lets it go
    /// (`tvPageClaimingFocus`). Set again until it lands, which overrides
    /// tvOS's own pick (a detail page's synopsis), but never after a press:
    /// re-setting it then pulled the press straight back (on CI's slower
    /// runner, Down from Play went back to Play, and the next Select played
    /// instead of opening the tile).
    private func claim(_ id: ID) {
        dbgLog.notice("claim \(String(describing: id), privacy: .public) onShow=\(isOnShow)")
        let pressesBefore = moves
        claiming()
        focus.wrappedValue = id
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                if focus.wrappedValue == id || moves != pressesBefore { break }
                focus.wrappedValue = id
            }
            claimed()
        }
    }
}
