import SwiftUI

/// A detail page inside the shell, with the rail beside it: chooses the page
/// for the item's kind and owns loading and failure. Its data is the shared
/// `AssetDetailViewModel`, which the shell keeps for as long as the page is
/// on the path.
struct TVDetailPage: View {
    let viewModel: AssetDetailViewModel
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @State private var isBelowHeader = false

    var body: some View {
        TVPageScaffold(background: { background }) {
            content
        }
        .task { await viewModel.loadIfNeeded() }
        // Back on show: a page above may have changed what this one shows
        // (a watched state, a resume point).
        .onChange(of: isOnShow) { _, onShow in
            if onShow, viewModel.loadState == .loaded { Task { await viewModel.refreshItem() } }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let item = viewModel.item { TVDetailBackdrop(item: item, isBlurred: isBelowHeader) }
    }

    /// A failed load wins over a preloaded item: the tile's own copy is too
    /// thin to stand in for the page.
    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = viewModel.loadState {
            TVPageMessage(
                title: String(localized: "Couldn't Load This Title"), message: message,
                actionTitle: "Try Again", actionIdentifier: A11yID.TV.Detail.retry
            ) { Task { await viewModel.load() } }
        } else if let item = viewModel.item {
            switch item.kind {
            default:
                TVMovieDetailView(viewModel: viewModel, item: item, client: client, userID: userID, rememberedFocus: $rememberedFocus, isBelowHeader: $isBelowHeader)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
