import SwiftUI

/// Search over the Jellyfin library. Results come straight from Jellyfin's
/// `/Search/Hints` endpoint (`SearchViewModel.results`) shown as a plain
/// list — that endpoint is fast enough to serve as the actual results, so
/// there's no separate typeahead-dropdown-vs-full-grid split.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SearchViewModel?
    /// Bound by `MainTabView` to the Search tab's `NavigationStack`, rather than
    /// a declarative `NavigationLink(value:)` as elsewhere: a row must both
    /// record the tap to search history and navigate, and
    /// `NavigationLink` + `.simultaneousGesture` is unreliable inside a `List`
    /// row, whose own tap handling can swallow the gesture. Pushing from the
    /// same `Button` action as `recordSelection` guarantees both.
    @Binding var path: [AppRoute]
    /// Bumped by `MainTabView` when the user re-taps the Search tab while
    /// already on it, observed below via `.onChange` to reset to the landing
    /// page. A plain `let`, since this view only reads it.
    let resetToken: Int
    /// True once the search field is focused, even before any text is typed; set
    /// by SwiftUI as a descendant of `.searchable`. Distinguishes the landing
    /// page (`false`: show history) from "tapped in, still empty" (`true`: show
    /// the placeholder) — history is a landing affordance, not something to
    /// linger once the field is engaged.
    @Environment(\.isSearching) private var isSearching
    /// Unfocuses the search field, dismissing the keyboard and Cancel button.
    /// Part of `reset()`, so re-tapping the Search tab mid-search doesn't leave
    /// the field focused and empty.
    @Environment(\.dismissSearch) private var dismissSearch

    /// `.searchable`'s `.automatic` placement resolves differently per size
    /// class: an always-visible inline field on `.compact`, but a
    /// magnifying-glass toolbar button on `.regular` that must be tapped before
    /// the field appears, making the landing page read as broken search.
    /// `.navigationBarDrawer(displayMode: .always)` on `.regular` matches
    /// iPhone's behavior.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var searchPlacement: SearchFieldPlacement {
        horizontalSizeClass == .regular ? .navigationBarDrawer(displayMode: .always) : .automatic
    }

    /// Same `.regular` gate as `searchPlacement`, swapping the presentation: a
    /// single-column `List` reads fine on `.compact` but leaves most of an
    /// iPad's width dead. `.regular` gets a `PosterGridMetrics`-driven grid,
    /// reusing `CollectionGridView`'s column fitting.
    private var usesGridLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: searchTextBinding, placement: searchPlacement, prompt: "Movies, shows, episodes\u{2026}")
            .task { await setUpIfNeeded() }
            .onChange(of: resetToken) { _, _ in reset() }
    }

    /// Clears the query and results and pops back to the landing page; see
    /// `resetToken` for when this fires.
    private func reset() {
        viewModel?.query = ""
        viewModel?.queryChanged()
        path = []
        dismissSearch()
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
        // Only gates `.searching`/`.failed`. `.idle` is handled by
        // `idleContent`, which does its own `LibraryAvailability`-based offline
        // handling, and `.loaded` is already on screen; a stale background
        // offline flag shouldn't blank either.
        if ConnectivityMonitor.shared.isOffline,
           viewModel?.loadState == .searching || isFailedState(viewModel?.loadState) {
            OfflineStateView(retry: { viewModel?.queryChanged() })
        } else {
            switch viewModel?.loadState ?? .idle {
            case .idle:
                idleContent
            case .searching:
                LoadingView()
            case .failed(let message):
                ErrorStateView(message: message, retry: nil)
            case .loaded:
                let results = viewModel?.results ?? []
                if results.isEmpty {
                    ContentUnavailableView.search
                        .accessibilityIdentifier(A11yID.Search.emptyState)
                } else if usesGridLayout {
                    resultsGrid(results)
                } else {
                    resultsList(results)
                }
            }
        }
    }

    /// Search makes no requests until a query is typed, so unlike
    /// `.searching`/`.failed` it has no failure to learn it's offline from. This
    /// mirrors `HomeViewModel`'s load state via `LibraryAvailability`, so the
    /// landing page shows the same "You're Offline" as Home and recovers when
    /// Home's own retry succeeds.
    @ViewBuilder
    private var idleContent: some View {
        switch LibraryAvailability.shared.state {
        case .loading:
            LoadingView()
        case .unavailable:
            OfflineStateView(retry: { LibraryAvailability.shared.retryAction?() })
        case .available:
            let history = viewModel?.history ?? []
            if !isSearching, !history.isEmpty {
                if usesGridLayout {
                    historyGrid(history)
                } else {
                    historyList(history)
                }
            } else {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Find movies, shows, and episodes on your server.")
                )
            }
        }
    }

    private func isFailedState(_ state: SearchViewModel.LoadState?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func resultsList(_ results: [SearchResult]) -> some View {
        let isLandscape = isLandscapeShape(results)
        return List(results) { result in
            row(for: result, isLandscape: isLandscape) { select(result) }
        }
        .listStyle(.plain)
    }

    private func historyList(_ history: [SearchResult]) -> some View {
        let isLandscape = isLandscapeShape(history)
        return List {
            Section {
                ForEach(history) { entry in
                    row(for: entry, isLandscape: isLandscape) { select(entry) }
                        // Trailing, matching the HIG direction for a destructive
                        // action and the Downloads lists' swipe-to-delete.
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                viewModel?.removeFromHistory(entry)
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

    /// `.regular` counterpart to `resultsList` (see `usesGridLayout`). No
    /// header, matching `resultsList`.
    private func resultsGrid(_ results: [SearchResult]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                grid(results, containerWidth: proxy.size.width, onRemove: nil)
                    .padding(.vertical)
            }
        }
    }

    /// `.regular` counterpart to `historyList`, reusing the same "Recent
    /// Searches"/"Clear All" header above the grid. Grid tiles have no swipe
    /// gesture for a per-entry delete, so `SearchResultGridCard` gets a corner
    /// button instead (`onRemove`) — the same circular-glyph-over-artwork idiom
    /// as `HeroRailView.heroNavigationButton`.
    private func historyGrid(_ history: [SearchResult]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recent Searches")
                            .font(.title3.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear All") { viewModel?.clearHistory() }
                            .font(.subheadline)
                    }
                    .padding(.horizontal)

                    grid(history, containerWidth: proxy.size.width) { entry in
                        viewModel?.removeFromHistory(entry)
                    }
                }
                .padding(.vertical)
            }
        }
    }

    /// Landscape if any item is series/episode-like
    /// (`SearchResult.isLandscapeShaped`), decided once for the whole
    /// list or grid rather than per item — the same rule as
    /// `MediaCollectionRail.usesLandscapeTiles`, which documents why a
    /// mixed-shape list reads worse than a consistent one. Shared by both
    /// presentations.
    private func isLandscapeShape(_ items: [SearchResult]) -> Bool {
        items.contains { $0.isLandscapeShaped }
    }

    /// Shared by `resultsGrid`/`historyGrid`; they differ only in whether tiles
    /// get a remove button (`onRemove`, `nil` for live results).
    private func grid(_ items: [SearchResult], containerWidth: CGFloat, onRemove: ((SearchResult) -> Void)?) -> some View {
        let isLandscape = isLandscapeShape(items)
        let metrics = PosterGridMetrics(containerWidth: containerWidth, idealItemWidth: isLandscape ? 260 : 160)
        return LazyVGrid(columns: metrics.columns, spacing: 20) {
            ForEach(items) { item in
                SearchResultGridCard(
                    result: item, imageURL: viewModel?.imageURL(for: item, preferLandscape: isLandscape),
                    width: metrics.itemWidth, isLandscape: isLandscape, onSelect: { select(item) },
                    onRemove: onRemove.map { remove in { remove(item) } }
                )
                // Same identifier, same reason, as `row(for:isLandscape:onSelect:)`.
                .accessibilityIdentifier(A11yID.Media.card(item.id))
            }
        }
        .padding(.horizontal)
    }

    /// Resolves `result`'s image URL here, where the `@Observable` access is
    /// tracked, rather than inside `SearchResultRow`; see
    /// `SearchViewModel.imageURL(for:)` for why it's resolved on demand rather
    /// than stored on `SearchResult`. `isLandscape` is the whole list's shape
    /// decision, not `result`'s own kind.
    private func row(for result: SearchResult, isLandscape: Bool, onSelect: @escaping () -> Void) -> some View {
        SearchResultRow(
            name: result.name, subtitle: result.subtitle,
            imageURL: viewModel?.imageURL(for: result, preferLandscape: isLandscape),
            kind: result.kind, isLandscape: isLandscape, onSelect: onSelect
        )
        // The same identifier `PosterCard` carries, so a test addresses a result
        // by the item it shows rather than its position, identically across
        // Home, grids and search. Applied here rather than in
        // `SearchResultRow`, which is shared with history entries and takes
        // flattened fields with no id.
        .accessibilityIdentifier(A11yID.Media.card(result.id))
    }

    /// Records `result` to search history then pushes its detail page, from one
    /// synchronous action; see `path` for why this replaced a declarative
    /// `NavigationLink`.
    private func select(_ result: SearchResult) {
        viewModel?.recordSelection(result)
        path.append(.assetDetail(itemID: result.id))
    }

    private func setUpIfNeeded() async {
        // Falls back to the cached `userID` from a prior sign-in, so a cold
        // launch that resumed `.main` from cache still builds a view model right
        // away. See `AppState.start()`.
        guard viewModel == nil, let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let newViewModel = SearchViewModel(client: client, userID: userID)
        viewModel = newViewModel
        await newViewModel.loadImagesIfNeeded()
    }
}

/// One row in `SearchView`'s results and history lists: thumbnail, name,
/// subtitle and a manually-added disclosure chevron, which a plain `Button`
/// row doesn't get for free. Takes already-resolved display fields rather than a
/// `SearchResult`, so it's agnostic of how `imageURL` was resolved.
private struct SearchResultRow: View {
    let name: String
    let subtitle: String?
    let imageURL: URL?
    /// Drives the thumbnail's placeholder glyph; `nil`, as on a history entry
    /// persisted before `SearchResult.kind` existed, falls back to a generic one.
    let kind: BaseItemKind?
    /// The whole list's shape decision (`SearchView.isLandscapeShape`), not this
    /// row's `kind`, so a movie in an episode-heavy list gets the same shape as
    /// every other row. Height stays at 44pt either way; only the width changes
    /// — landscape from `PosterCard`'s poster ratio inverted (`height / 1.5`,
    /// since height is what's fixed), portrait from `LandscapeMediaCard`'s 16:9.
    let isLandscape: Bool
    let onSelect: () -> Void

    private static let imageHeight: CGFloat = 44
    private var imageWidth: CGFloat { isLandscape ? Self.imageHeight * 16 / 9 : Self.imageHeight / 1.5 }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncRemoteImage(url: imageURL, placeholderSystemImage: kind?.placeholderSystemImage ?? "photo")
                    .frame(width: imageWidth, height: Self.imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if let subtitle {
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
            // Without this a `Button` hit-tests only its label's rendered
            // pixels, leaving the `Spacer()` and padding as dead zones that
            // swallow taps. `NavigationLink` hit-tests its whole row
            // automatically, which is why this wasn't needed before the switch
            // to a plain `Button`.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.regular` counterpart to `SearchResultRow`: a poster or landscape tile
/// borrowing `PosterCard`/`LandscapeMediaCard`'s visual language rather than
/// those views, which `SearchResult`'s thinner model doesn't fit. No
/// watch-status or favorite overlay, since `SearchResult` carries no `userData`.
private struct SearchResultGridCard: View {
    let result: SearchResult
    let imageURL: URL?
    let width: CGFloat
    let isLandscape: Bool
    let onSelect: () -> Void
    /// `nil` for a live search result; non-`nil` for a history entry, rendering
    /// the corner button below.
    var onRemove: (() -> Void)?

    private var imageHeight: CGFloat { isLandscape ? width * 9 / 16 : width * 1.5 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    AsyncRemoteImage(url: imageURL, placeholderSystemImage: result.kind?.placeholderSystemImage ?? "photo")
                        .frame(width: width, height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if let subtitle = result.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: width)
                .contentShape(Rectangle())
                // Same house pattern as `PosterCard`/`LandscapeMediaCard`/
                // `LibraryCard`.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(result.accessibilityDescription)
                .accessibilityAddTraits(.isButton)
            }
            .buttonStyle(.plain)

            if let onRemove {
                // The circular-glyph-over-artwork idiom
                // `HeroRailView.heroNavigationButton` uses, since a grid tile has
                // no swipe gesture for a delete affordance. The visible circle is
                // 24pt, sized for a tile this size, while the outer
                // `.frame`+`.contentShape` grow the tap target to HIG's 44x44pt
                // minimum.
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(6)
                .accessibilityLabel(Text("Remove from history"))
            }
        }
    }
}

#Preview {
    NavigationStack { SearchView(path: .constant([]), resetToken: 0) }
        .environment(AppState())
}
