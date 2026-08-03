import SwiftUI

/// Loads an item and dispatches to the Movie or Show detail layout based on
/// its type.
struct AssetDetailView: View {
    let itemID: String

    @Environment(AppState.self) private var appState
    @State private var viewModel: AssetDetailViewModel?

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .task { await setUpIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            LoadingView()
        case .failed(let message):
            ErrorStateView(message: message) { Task { await viewModel?.load() } }
        case .loaded:
            if let viewModel, let item = viewModel.item {
                switch item.kind {
                case .series:
                    ShowDetailView(viewModel: viewModel)
                default:
                    MovieDetailView(viewModel: viewModel)
                }
            }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        let newViewModel = AssetDetailViewModel(client: client, userID: userID, itemID: itemID)
        viewModel = newViewModel
        await newViewModel.loadIfNeeded()
    }
}
