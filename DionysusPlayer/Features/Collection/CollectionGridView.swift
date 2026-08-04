import SwiftUI

/// A grid of a collection's items — a library (all Movies), a BoxSet, or
/// any other parent/filter combination described by a `CollectionQuery`.
struct CollectionGridView: View {
    let query: CollectionQuery

    @Environment(AppState.self) private var appState
    @State private var viewModel: CollectionGridViewModel?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(containerWidth: proxy.size.width)
                    .padding()
            }
        }
        .navigationTitle(query.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await setUpIfNeeded() }
    }

    @ViewBuilder
    private func content(containerWidth: CGFloat) -> some View {
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
                let metrics = PosterGridMetrics(containerWidth: containerWidth)
                LazyVGrid(columns: metrics.columns, spacing: 20) {
                    ForEach(items) { item in
                        PosterCard(item: item, width: metrics.itemWidth)
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
