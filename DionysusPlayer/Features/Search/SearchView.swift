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
    /// Bumped by `MainTabView` whenever the user re-taps the Search tab
    /// while already on it (not when switching into Search from another
    /// tab) — observed below via `.onChange` to reset back to the landing
    /// page. A plain `let`, not a `@Binding`: this view only ever needs to
    /// react to it changing, never write it.
    let resetToken: Int
    /// True once the search field is focused/active, even before any text
    /// is typed — set by SwiftUI as a descendant of `.searchable` below.
    /// Distinguishes the true landing page (this is `false`: show history,
    /// if any) from "tapped in, still empty" (this is `true`: show the
    /// plain placeholder, same as before — the history list is a landing
    /// affordance, not something that should linger once you've engaged
    /// the field to start typing).
    @Environment(\.isSearching) private var isSearching
    /// Deactivates the search field (unfocuses it, dismisses the keyboard/
    /// Cancel button) — part of `reset()`, so re-tapping the Search tab
    /// while mid-search doesn't just clear the query but leave the field
    /// awkwardly still focused and empty.
    @Environment(\.dismissSearch) private var dismissSearch

    /// `.searchable`'s own `.automatic` placement (the default, left
    /// implicit before this) resolves differently per size class: on
    /// `.compact` (iPhone) it's an always-visible inline field right below
    /// the nav bar, but on `.regular` (iPad, and iPhone Pro Max/Plus/Air in
    /// landscape) it collapses to a small magnifying-glass toolbar button
    /// that has to be tapped before the field even appears — confirmed live
    /// during an iPad HIG review (2026-09-03) as a real point of friction,
    /// not just a visual quirk: the landing page reads as "broken search"
    /// rather than "ready to search". Forcing `.navigationBarDrawer(
    /// displayMode: .always)` on `.regular` matches it to iPhone's own
    /// existing (already-correct, left alone here) behavior instead of
    /// leaving `.automatic` to pick the collapsed toolbar variant.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var searchPlacement: SearchFieldPlacement {
        horizontalSizeClass == .regular ? .navigationBarDrawer(displayMode: .always) : .automatic
    }

    /// Same `.regular` gate as `searchPlacement` above, this time swapping
    /// the results/history presentation itself: a full-bleed, single-column
    /// `List` (`resultsList`/`historyList`) reads fine on `.compact`
    /// (iPhone) but left most of an iPad's width as dead space — the same
    /// "unmodified iPhone layout" issue Home's rails had. `.regular` gets a
    /// `PosterGridMetrics`-driven grid (`resultsGrid`/`historyGrid`)
    /// instead, reusing the exact column-fitting approach
    /// `CollectionGridView` already established; `.compact` keeps today's
    /// list untouched.
    private var usesGridLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: searchTextBinding, placement: searchPlacement, prompt: "Movies, shows, episodes\u{2026}")
            .task { await setUpIfNeeded() }
            .onChange(of: resetToken) { _, _ in reset() }
    }

    /// Clears the query/results and pops back to the landing page — see
    /// `resetToken`'s doc comment for when this fires.
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
        // Only gates `.searching`/`.failed` — `.idle` is handled by
        // `idleContent` below (which has its own, `LibraryAvailability`-based
        // offline handling), and `.loaded` is content already on screen;
        // neither should be blanked out by a stale/background offline flag.
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
                } else if usesGridLayout {
                    resultsGrid(results)
                } else {
                    resultsList(results)
                }
            }
        }
    }

    /// Search has no network activity of its own until a query is typed,
    /// so — unlike `.searching`/`.failed` above — it has no live request
    /// whose failure would tell it the app is offline. This mirrors
    /// `HomeViewModel`'s own load state instead (via `LibraryAvailability`,
    /// see that type's doc comment), so the landing page shows the same
    /// "You're Offline" Home does whenever Home's own content isn't
    /// available yet, and switches back to normal — no action needed here
    /// — the moment Home's own retry/reconnect handling succeeds.
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
                        // Trailing (swipe-left-to-reveal), matching both the
                        // HIG-standard direction for a destructive action
                        // and every Downloads list's own swipe-to-delete
                        // (`DownloadsView`/`DownloadedShowView`/
                        // `DownloadedSeasonView`) — this used to be a
                        // deliberately reversed leading-edge swipe with no
                        // recorded rationale; aligned 2026-08-31.
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

    /// `.regular`-size-class counterpart to `resultsList` — see
    /// `usesGridLayout`'s doc comment for why this exists at all. No header,
    /// matching `resultsList`'s own lack of one.
    private func resultsGrid(_ results: [SearchResult]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                grid(results, containerWidth: proxy.size.width, onRemove: nil)
                    .padding(.vertical)
            }
        }
    }

    /// `.regular`-size-class counterpart to `historyList` — same "Recent
    /// Searches"/"Clear All" header, reused verbatim above the grid rather
    /// than duplicated. Grid tiles have no swipe gesture to hang a per-entry
    /// delete off of the way `historyList`'s row does, so
    /// `SearchResultGridCard` gets a small corner button instead (see
    /// `onRemove` below) — same visual language (a circular glyph button
    /// over the artwork) `HeroRailView.heroNavigationButton` already uses
    /// elsewhere in the app.
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

    /// Landscape if *any* item is series/episode-like (`SearchResult
    /// .isLandscapeShaped`), decided once for the whole list/grid, not per
    /// item — mirrors `MediaCollectionRail.usesLandscapeTiles`'s exact rule
    /// (see that property's doc comment for why a mixed-shape rail/grid/
    /// list reads worse than a consistent one) rather than inventing a
    /// different rule for search results. Shared by both presentations:
    /// `grid` (the `.regular` tile shape) and `resultsList`/`historyList`
    /// (the `.compact` row's thumbnail shape).
    private func isLandscapeShape(_ items: [SearchResult]) -> Bool {
        items.contains { $0.isLandscapeShaped }
    }

    /// Shared by `resultsGrid`/`historyGrid` — the only difference between
    /// the two is whether tiles get a remove button (`onRemove`, `nil` for
    /// live results).
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
            }
        }
        .padding(.horizontal)
    }

    /// Resolves `result`'s image URL against the ViewModel's current
    /// `ImageURLBuilder` here (at the `SearchView` level, where the
    /// `@Observable` access is tracked) rather than inside `SearchResultRow`
    /// itself — see `SearchViewModel.imageURL(for:)`'s doc comment for why
    /// it's resolved on demand instead of stored on `SearchResult`. `isLandscape`
    /// is the whole list's one shape decision (`isLandscapeShape(_:)`), not
    /// `result`'s own kind — same reasoning as the grid's `SearchResultGridCard`.
    private func row(for result: SearchResult, isLandscape: Bool, onSelect: @escaping () -> Void) -> some View {
        SearchResultRow(
            name: result.name, subtitle: result.subtitle,
            imageURL: viewModel?.imageURL(for: result, preferLandscape: isLandscape),
            kind: result.kind, isLandscape: isLandscape, onSelect: onSelect
        )
    }

    /// Records `result` to search history and pushes its detail page, in
    /// that order, from the same synchronous action — see `path`'s doc
    /// comment for why this replaced a declarative `NavigationLink`.
    private func select(_ result: SearchResult) {
        viewModel?.recordSelection(result)
        path.append(.assetDetail(itemID: result.id))
    }

    private func setUpIfNeeded() async {
        // Falls back to the cached `userID` from a prior sign-in (same
        // idiom `PlayerView` uses) so this still constructs a view model
        // right away on a cold launch that resumed `.main` from cache
        // rather than a fresh sign-in — see `AppState.start()`.
        guard viewModel == nil, let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let newViewModel = SearchViewModel(client: client, userID: userID)
        viewModel = newViewModel
        await newViewModel.loadImagesIfNeeded()
    }
}

/// One row in `SearchView`'s results/history lists — a compact thumbnail/
/// name/subtitle layout plus a trailing disclosure chevron (added manually
/// since a plain `Button` row, unlike `NavigationLink`, doesn't get one for
/// free), distinct from `PosterCard`'s full poster treatment since these
/// are meant to be scanned quickly. Takes already-resolved display fields
/// rather than a `SearchResult` directly, so it stays agnostic of how
/// `imageURL` got resolved.
private struct SearchResultRow: View {
    let name: String
    let subtitle: String?
    let imageURL: URL?
    /// Drives the thumbnail's placeholder glyph — `nil` (e.g. a history
    /// entry persisted before `SearchResult.kind` existed) falls back to a
    /// generic glyph.
    let kind: BaseItemKind?
    /// The whole list's one shape decision (`SearchView.isLandscapeShape`),
    /// not this row's own `kind` — a movie mixed into an otherwise
    /// episode-heavy list gets the same landscape thumbnail shape as every
    /// other row here, matching `SearchResultGridCard`'s identical rule for
    /// the `.regular` grid. Height stays fixed at the row's own 44pt either
    /// way; only the width (and therefore aspect ratio) changes — landscape
    /// derives its width from `PosterCard`'s poster ratio (`height / 1.5`,
    /// inverted since this fixes height rather than width), portrait from
    /// `LandscapeMediaCard`'s 16:9 (`height * 16 / 9`).
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

/// `.regular`-size-class counterpart to `SearchResultRow` — a poster/
/// landscape-style tile (visual language borrowed from `PosterCard`/
/// `LandscapeMediaCard`, not those views themselves; see `PosterCard`'s own
/// doc comment for why `SearchResult`'s thinner model doesn't fit them
/// directly). No watch-status/favorite overlay — `SearchResult` carries no
/// `userData` to draw one from, same gap `SearchResultRow` already has.
private struct SearchResultGridCard: View {
    let result: SearchResult
    let imageURL: URL?
    let width: CGFloat
    let isLandscape: Bool
    let onSelect: () -> Void
    /// `nil` for a live search result (nothing to remove); non-`nil` for a
    /// history entry, rendering the small corner button below.
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
                // `LibraryCard` — see any of their identical blocks for why.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(result.accessibilityDescription)
                .accessibilityAddTraits(.isButton)
            }
            .buttonStyle(.plain)

            if let onRemove {
                // Same circular-glyph-over-artwork idiom
                // `HeroRailView.heroNavigationButton` already uses — a grid
                // tile has no swipe gesture to hang a delete affordance off
                // of the way `historyList`'s row does. Unlike that button,
                // this one's *visible* circle is deliberately smaller (24pt,
                // sized to look right on a tile this size) than its
                // *tappable* area — the outer `.frame`+`.contentShape` grow
                // the actual tap target to the same 44x44pt
                // `heroNavigationButton` uses outright, matching HIG's
                // mobile minimum control size. Found during an iPad HIG
                // review (2026-09-03): this used to size the button to the
                // glyph itself (24x24), under HIG's stated 28x28 floor.
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
