import SwiftUI

/// Search over the Jellyfin library. Results come straight from Jellyfin's
/// `/Search/Hints` endpoint (`SearchViewModel.results`) shown as a plain
/// list — that endpoint is fast enough to serve as the actual results, so
/// there's no separate typeahead-dropdown-vs-full-grid split.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SearchViewModel?
    /// Bound by `MainTabView` to the Search tab's own `NavigationStack`,
    /// rather than pushing via a plain declarative `NavigationLink(value:)`
    /// like everywhere else — a row here needs to both record the tap to
    /// search history *and* navigate, and doing that via
    /// `NavigationLink` + `.simultaneousGesture` turned out to be
    /// unreliable inside a `List` row (the row's own tap handling can
    /// swallow the simultaneous gesture). Pushing manually from inside the
    /// same `Button` action that calls `recordSelection` guarantees both
    /// happen together, every time.
    @Binding var path: [AppRoute]
    /// True once the search field is focused/active, even before any text
    /// is typed — set by SwiftUI as a descendant of `.searchable` below.
    /// Distinguishes the true landing page (this is `false`: show history,
    /// if any) from "tapped in, still empty" (this is `true`: show the
    /// plain placeholder, same as before — the history list is a landing
    /// affordance, not something that should linger once you've engaged
    /// the field to start typing).
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        content
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
    private var content: some View {
        switch viewModel?.loadState ?? .idle {
        case .idle:
            let history = viewModel?.history ?? []
            if !isSearching, !history.isEmpty {
                historyList(history)
            } else {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Find movies, shows, and episodes on your server.")
                )
            }
        case .searching:
            LoadingView()
        case .failed(let message):
            ErrorStateView(message: message, retry: nil)
        case .loaded:
            let results = viewModel?.results ?? []
            if results.isEmpty {
                ContentUnavailableView.search
            } else {
                resultsList(results)
            }
        }
    }

    private func resultsList(_ results: [SearchResult]) -> some View {
        List(results) { result in
            SearchResultRow(result: result) { select(result) }
        }
        .listStyle(.plain)
    }

    private func historyList(_ history: [SearchResult]) -> some View {
        List {
            Section {
                ForEach(history) { entry in
                    SearchResultRow(result: entry) { select(entry) }
                        // Leading (swipe-right-to-reveal), not the more
                        // common trailing swipe-left — per an explicit
                        // design call, not the default.
                        .swipeActions(edge: .leading) {
                            Button(role: .destructive) {
                                viewModel?.removeFromHistory(entry)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear All") { viewModel?.clearHistory() }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }

    /// Records `result` to search history and pushes its detail page, in
    /// that order, from the same synchronous action — see `path`'s doc
    /// comment for why this replaced a declarative `NavigationLink`.
    private func select(_ result: SearchResult) {
        viewModel?.recordSelection(result)
        path.append(.assetDetail(itemID: result.id))
    }

    private func setUpIfNeeded() {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        viewModel = SearchViewModel(client: client, userID: userID)
    }
}

/// One row in `SearchView`'s results/history lists — a compact thumbnail/
/// name/subtitle layout plus a trailing disclosure chevron (added manually
/// since a plain `Button` row, unlike `NavigationLink`, doesn't get one for
/// free), distinct from `PosterCard`'s full poster treatment since these
/// are meant to be scanned quickly.
private struct SearchResultRow: View {
    let result: SearchResult
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncRemoteImage(url: result.imageURL)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                    if let subtitle = result.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            // Without this, a `Button`'s hit-testing only covers its
            // label's actual rendered pixels (the image/text/chevron) —
            // the `Spacer()` and any padding in between are dead zones
            // that silently swallow a tap instead of triggering `onSelect`.
            // `NavigationLink` doesn't have this problem (it hit-tests its
            // whole row automatically), which is exactly why this wasn't
            // needed before switching to a plain `Button` for reliable
            // history recording — this is what makes the *entire* row
            // tappable again, not just the visible content within it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack { SearchView(path: .constant([])) }
        .environment(AppState())
}
