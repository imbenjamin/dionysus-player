import Observation
import SwiftUI

/// A `dionysus://item` link's `season=` and `section=` (#406), waiting for
/// the title's page. `MainTabView` pushes the page and posts the cue; the
/// page takes it once it has loaded, opens the season, scrolls to the
/// section, and says in one toast what it doesn't have.
@Observable
@MainActor
final class DeepLinkPageCue {
    static let shared = DeepLinkPageCue()

    struct Cue: Equatable {
        var pageID: String
        var options: DeepLink.ItemOptions
        /// What the link couldn't read, said with what the page finds.
        var notices: [String] = []
    }

    private(set) var cue: Cue?

    /// The page the cue is for, until that page takes it.
    var pageID: String? { cue?.pageID }

    func post(_ cue: Cue) { self.cue = cue }

    func clear() { cue = nil }

    /// The cue, if it's for that page; taking it clears it, so it applies once.
    func take(for pageID: String) -> Cue? {
        guard let cue, cue.pageID == pageID else { return nil }
        self.cue = nil
        return cue
    }
}

extension View {
    /// Applies a cued item link (`DeepLinkPageCue`) once `viewModel` has
    /// loaded. `apply` opens what the page has and returns a notice for each
    /// part it doesn't; those and the link's own are said in one toast.
    func takesDeepLinkPageCue(
        _ viewModel: AssetDetailViewModel, apply: @escaping (DeepLink.ItemOptions) -> [String]
    ) -> some View {
        modifier(DeepLinkPageCueTaker(viewModel: viewModel, apply: apply))
    }
}

private struct DeepLinkPageCueTaker: ViewModifier {
    let viewModel: AssetDetailViewModel
    let apply: (DeepLink.ItemOptions) -> [String]

    func body(content: Content) -> some View {
        content
            .onChange(of: DeepLinkPageCue.shared.pageID, initial: true) { takeCue() }
            .onChange(of: viewModel.loadState) { takeCue() }
    }

    private func takeCue() {
        let center = DeepLinkPageCue.shared
        guard center.pageID == viewModel.itemID, viewModel.loadState == .loaded,
              let cue = center.take(for: viewModel.itemID) else { return }
        let notices = cue.notices + apply(cue.options)
        if !notices.isEmpty { ToastCenter.shared.post(.notice(notices.joined(separator: " "))) }
    }
}

/// Where a page scrolls for a link's section (`DeepLinkPageCue`), as
/// `ScrollViewReader` ids.
enum DeepLinkPageAnchor: Hashable {
    case tabs, chapters, seasons, similar
}

extension ScrollViewProxy {
    /// Scrolls to a link's section once the page has laid out what it just
    /// opened (a tab, a season).
    @MainActor
    func scrollToLinkedSection(_ anchor: DeepLinkPageAnchor) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation { scrollTo(anchor, anchor: .top) }
        }
    }
}

/// Where a link's section is on a title's page, if the page has it.
enum DeepLinkPageSection: Equatable {
    case tab(LinkedDetailTab.Tab)
    case anchor(DeepLinkPageAnchor)

    /// `item` is what the page's tabs and chapter rail describe;
    /// `showsChapters` whether the page draws that rail.
    static func target(
        for section: DeepLink.ItemOptions.Section, item: MediaItem, showsChapters: Bool, hasSimilar: Bool
    ) -> DeepLinkPageSection? {
        switch section {
        case .cast: item.cast.isEmpty ? nil : .tab(.cast)
        case .details: item.technicalDetails == nil ? nil : .tab(.details)
        case .chapters: showsChapters && !item.chapters.isEmpty ? .anchor(.chapters) : nil
        case .similar: hasSimilar ? .anchor(.similar) : nil
        }
    }
}
