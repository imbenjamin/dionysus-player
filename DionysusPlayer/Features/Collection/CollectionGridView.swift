import SwiftUI

/// A grid of a collection's items — a library (all Movies), a BoxSet, or
/// any other parent/filter combination described by a `CollectionQuery`.
struct CollectionGridView: View {
    let query: CollectionQuery

    @Environment(AppState.self) private var appState
    @State private var viewModel: CollectionGridViewModel?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            content
                .padding()
        }
        .navigationTitle(query.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await setUpIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            LoadingView().frame(minHeight: 300)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await viewModel?.load() } }
                .frame(minHeight: 300)
        case .loaded:
            let items = viewModel?.items ?? []
            if items.isEmpty {
                ErrorStateView(message: "Nothing here yet.", retry: nil)
                    .frame(minHeight: 300)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        PosterCard(item: item, width: 130)
                    }
                }
            }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        let newViewModel = CollectionGridViewModel(client: client, userID: userID, query: query)
        viewModel = newViewModel
        await newViewModel.loadIfNeeded()
    }
}

#Preview {
    NavigationStack {
        CollectionGridView(query: CollectionQuery(title: "Movies", includeItemTypes: ["Movie"]))
    }
    .environment(AppState())
}
