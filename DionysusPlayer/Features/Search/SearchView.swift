import SwiftUI

/// Basic search over the Jellyfin library, with results shown in the same
/// grid layout as the Collection screen.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SearchViewModel?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(containerWidth: proxy.size.width)
                    .padding()
            }
        }
        .navigationTitle("Search")
        .searchable(text: searchTextBinding, prompt: "Movies, shows, episodes\u{2026}")
        .task { setUpIfNeeded() }
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel?.query ?? "" },
            set: { newValue in
                viewModel?.query = newValue
                viewModel?.queryChanged()
            }
        )
    }

    @ViewBuilder
    private func content(containerWidth: CGFloat) -> some View {
        switch viewModel?.loadState ?? .idle {
        case .idle:
            ContentUnavailableView(
                "Search Your Library",
                systemImage: "magnifyingglass",
                description: Text("Find movies, shows, and episodes on your server.")
            )
        case .searching:
            LoadingView().frame(minHeight: 200)
        case .failed(let message):
            ErrorStateView(message: message, retry: nil)
                .frame(minHeight: 200)
        case .loaded:
            let results = viewModel?.results ?? []
            if results.isEmpty {
                ContentUnavailableView.search
            } else {
                let metrics = PosterGridMetrics(containerWidth: containerWidth)
                LazyVGrid(columns: metrics.columns, spacing: 20) {
                    ForEach(results) { item in
                        PosterCard(item: item, width: metrics.itemWidth)
                    }
                }
            }
        }
    }

    private func setUpIfNeeded() {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        viewModel = SearchViewModel(client: client, userID: userID)
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(AppState())
}
