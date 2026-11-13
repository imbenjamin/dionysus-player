import SwiftUI

/// A `dionysus://item` link's `season=` and `section=` (#406), held by the
/// shell for the page it pushed until the page has loaded and applied it.
struct TVLinkedItemOptions: Equatable {
    var options: DeepLink.ItemOptions
    /// What the link couldn't read, said with what the page finds.
    var notices: [String] = []
}

extension DeepLink.ItemOptions.Section {
    /// What the Apple TV says when its page doesn't have this section:
    /// chapters aren't drawn on its pages at all.
    var tvMissingNotice: String {
        self == .chapters ? String(localized: "Chapters aren't shown on Apple TV's pages.") : missingNotice
    }
}

extension View {
    /// Applies a linked season and section once `viewModel` has loaded:
    /// `apply` opens what the page has and names the item to focus, which
    /// scrolls the page there (`tvDetailLanding`), and says what it doesn't
    /// have. The link is cleared once focus has held, so it applies once.
    func tvAppliesItemLink(
        _ link: Binding<TVLinkedItemOptions?>, viewModel: AssetDetailViewModel, focus: FocusState<String?>.Binding,
        apply: @escaping (DeepLink.ItemOptions) -> (focus: String?, notices: [String])
    ) -> some View {
        modifier(TVItemLinkApplier(link: link, viewModel: viewModel, focus: focus, apply: apply))
    }
}

private struct TVItemLinkApplier: ViewModifier {
    @Binding var link: TVLinkedItemOptions?
    let viewModel: AssetDetailViewModel
    let focus: FocusState<String?>.Binding
    let apply: (DeepLink.ItemOptions) -> (focus: String?, notices: [String])

    func body(content: Content) -> some View {
        content.task(id: link != nil && viewModel.loadState == .loaded) {
            guard let linked = link, viewModel.loadState == .loaded else { return }
            // Cleared once the hold below is done (or the page goes), never
            // first: clearing it changes this task's id, which cancelled the
            // hold after its first pass, and the page's own claim then put
            // focus back on Play (#462).
            defer { link = nil }
            let result = apply(linked.options)
            let notices = linked.notices + result.notices
            if !notices.isEmpty { ToastCenter.shared.post(.notice(notices.joined(separator: " "))) }
            guard let target = result.focus else { return }
            // The page claims its default item and the shell hands focus to
            // the page as it's pushed, both after this can run, and either
            // puts focus back on Play. So it's asked for again until it has
            // stayed on the target for half a second, for three at most.
            var settled = 0
            for _ in 0..<30 where settled < 5 {
                guard !Task.isCancelled else { return }
                if focus.wrappedValue == target {
                    settled += 1
                } else {
                    settled = 0
                    focus.wrappedValue = target
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
