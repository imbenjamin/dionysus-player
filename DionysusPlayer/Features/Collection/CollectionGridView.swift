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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task { await setUpIfNeeded() }
    }

    /// Two independent `Picker` groups in one `Menu` — field and direction
    /// are separate axes, so any field (not just Title) can go either
    /// ascending or descending. Always shown, regardless of load state —
    /// lets the user pick a different ordering even before/during a failed
    /// load, same as any other standing toolbar control.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: sortFieldBinding) {
                Text("Title").tag(CollectionSortField.title)
                Text("Date Added").tag(CollectionSortField.dateAdded)
                Text("Release Date").tag(CollectionSortField.releaseDate)
            }
            Picker("Order", selection: sortOrderBinding) {
                Text("Ascending").tag(CollectionSortOrder.ascending)
                Text("Descending").tag(CollectionSortOrder.descending)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var sortFieldBinding: Binding<CollectionSortField> {
        Binding(
            get: { viewModel?.sortField ?? .title },
            set: { newValue in Task { await viewModel?.setSortField(newValue) } }
        )
    }

    private var sortOrderBinding: Binding<CollectionSortOrder> {
        Binding(
            get: { viewModel?.sortOrder ?? .ascending },
            set: { newValue in Task { await viewModel?.setSortOrder(newValue) } }
        )
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
                ErrorStateView(message: String(localized: "Nothing here yet."), retry: nil)
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
