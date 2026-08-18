import SwiftUI
import UIKit

/// A grid of a collection's items — a library (all Movies), a BoxSet, or
/// any other parent/filter combination described by a `CollectionQuery`.
struct CollectionGridView: View {
    let query: CollectionQuery

    @Environment(AppState.self) private var appState
    @State private var viewModel: CollectionGridViewModel?
    /// Drives the dice button's push — a local `MediaItem?` binding rather
    /// than going through `AppRoute`/`.navigationDestination(for:)` (already
    /// registered once, up in `MainTabView`'s `NavigationStack`): a second
    /// `navigationDestination` for the same `AppRoute` type nested inside
    /// that stack is ambiguous per SwiftUI's own docs, so this uses its own
    /// item type instead of fighting that registration.
    @State private var randomPick: MediaItem?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(containerWidth: proxy.size.width)
                    .padding()
            }
        }
        .navigationTitle(query.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $randomPick) { item in
            randomDestination(for: item)
        }
        .toolbar {
            // Two separate `ToolbarItem`s — on iOS 26, standing adjacent
            // trailing items still default to sharing one Liquid Glass
            // background regardless of whether they're grouped via
            // `ToolbarItemGroup`; splitting into separate `ToolbarItem`s
            // alone doesn't break that. `ToolbarSpacer(.fixed)` is the
            // actual iOS 26 API for forcing a visual break between two
            // items into their own separate glass capsules — sort and
            // random are unrelated actions, so they get one each, same as
            // `ResetFiltersButton` gets its own circle rather than joining
            // the filter pills' shared container. No pre-26 fallback is
            // needed here: before iOS 26, adjacent toolbar items were never
            // fused into shared glass in the first place.
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) { randomButton }
        }
        .task { await setUpIfNeeded() }
    }

    /// Jumps straight to a uniformly-random item out of whatever's currently
    /// filtered/sorted into view — a "surprise me" shortcut for browsing a
    /// large grid. Disabled once there's nothing left to pick from (e.g. a
    /// filter combination with zero matches).
    private var randomButton: some View {
        Button {
            randomPick = viewModel?.randomItem()
        } label: {
            Image(systemName: "dice")
        }
        .disabled((viewModel?.filteredItems ?? []).isEmpty)
    }

    /// Mirrors `AppRouteDestinationView`'s `.assetDetail` branch — kept as
    /// its own small builder here rather than routed through `AppRoute`
    /// itself, per `randomPick`'s doc comment.
    @ViewBuilder
    private func randomDestination(for item: MediaItem) -> some View {
        if let client = appState.apiClient, let userID = appState.currentUser?.id {
            AssetDetailView(itemID: item.id, preloadedItem: item, client: client, userID: userID)
        } else {
            ErrorStateView(message: String(localized: "You're not signed in."), retry: nil)
        }
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

    /// A row of pill buttons, one per facet that actually has values to
    /// offer (a facet with nothing available — e.g. no Studios data at
    /// all — doesn't show a dead control). Each of the five opens a `Menu`
    /// listing that facet's values, narrowing the grid down by one value at
    /// a time (not multi-select within a facet), combined with AND across
    /// facets in `CollectionGridViewModel.filteredItems`. Reset sits
    /// *outside* the scrolling pills, anchored
    /// at the trailing edge — as a same-shape "Reset" pill inside the
    /// scroll row it read as just a fourth filter option; a visually
    /// distinct circular icon button in a fixed position reads as the
    /// separate "clear everything" action it actually is.
    ///
    /// On iOS 26+ the pills sit inside a `GlassEffectContainer` — required
    /// (not just decorative) for multiple adjacent `.glassEffect` shapes to
    /// blend/sample as one coherent material instead of each rendering an
    /// independent, potentially-overlapping glass pass. Pre-26 falls back
    /// to a plain `HStack` with `FilterPill`'s original flat-color style
    /// (see its own `#available` branch).
    ///
    /// `.scrollClipDisabled()` on the horizontal scroll view: without it,
    /// the scroll view clips to its own (pill-height-tight) bounds, cutting
    /// the glass/shadow each pill casts off hard at the top/bottom edge
    /// instead of letting it blend softly into the page the way it does on
    /// every other pill-shaped control in this app.
    @ViewBuilder
    private var filterRow: some View {
        let genres = viewModel?.availableGenres ?? []
        let studios = viewModel?.availableStudios ?? []
        let decades = viewModel?.availableDecades ?? []
        let watchStatuses = viewModel?.availableWatchStatuses ?? []
        let favoriteStatuses = viewModel?.availableFavoriteStatuses ?? []

        if !genres.isEmpty || !studios.isEmpty || !decades.isEmpty || !watchStatuses.isEmpty || !favoriteStatuses.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    if #available(iOS 26.0, *) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                filterPills(
                                    genres: genres, studios: studios, decades: decades,
                                    watchStatuses: watchStatuses, favoriteStatuses: favoriteStatuses
                                )
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            filterPills(
                                genres: genres, studios: studios, decades: decades,
                                watchStatuses: watchStatuses, favoriteStatuses: favoriteStatuses
                            )
                        }
                    }
                }
                .scrollClipDisabled()

                if viewModel?.hasActiveFilters == true {
                    ResetFiltersButton { viewModel?.resetFilters() }
                }
            }
        }
    }

    @ViewBuilder
    private func filterPills(
        genres: [String], studios: [String], decades: [Int],
        watchStatuses: [CollectionWatchStatus], favoriteStatuses: [CollectionFavoriteStatus]
    ) -> some View {
        if !genres.isEmpty {
            FilterMenu(
                title: String(localized: "Genre"), allLabel: String(localized: "All Genres"),
                options: genres, display: { $0 }, systemImage: genreSystemImage, selection: genreBinding
            )
        }
        if !studios.isEmpty {
            FilterMenu(
                title: studioFilterTitle, allLabel: studioFilterAllLabel,
                options: studios, display: { $0 }, systemImage: studioSystemImage, selection: studioBinding
            )
        }
        if !decades.isEmpty {
            FilterMenu(
                title: String(localized: "Decade"), allLabel: String(localized: "All Decades"),
                options: decades, display: { "\($0)s" }, systemImage: decadeSystemImage, selection: decadeBinding
            )
        }
        if !watchStatuses.isEmpty {
            FilterMenu(
                title: String(localized: "Watched"), allLabel: String(localized: "All"),
                options: watchStatuses, display: watchStatusLabel,
                systemImage: watchStatusSystemImage, selection: watchStatusBinding
            )
        }
        if !favoriteStatuses.isEmpty {
            FilterMenu(
                title: String(localized: "Favorites"), allLabel: String(localized: "All Items"),
                options: favoriteStatuses, display: favoriteStatusLabel,
                systemImage: favoriteStatusSystemImage, selection: favoriteStatusBinding
            )
        }
    }

    /// Outline while "All Genres" is in effect, filled once an actual genre
    /// is picked — same active/inactive-by-fill convention `FilterPill`
    /// already used for its glass tint, just carried into the glyph too.
    /// `studioSystemImage`/`decadeSystemImage` mirror this.
    private var genreSystemImage: String {
        viewModel?.selectedGenre == nil ? "theatermasks" : "theatermasks.fill"
    }

    private var studioSystemImage: String {
        viewModel?.selectedStudio == nil ? "building.2" : "building.2.fill"
    }

    /// `clock`/`clock.fill` rather than `calendar` — SF Symbols has no
    /// `calendar.fill` counterpart to switch to once a decade is selected.
    private var decadeSystemImage: String {
        viewModel?.selectedDecade == nil ? "clock" : "clock.fill"
    }

    private func watchStatusLabel(_ status: CollectionWatchStatus) -> String {
        switch status {
        case .watched: String(localized: "Watched")
        case .unwatched: String(localized: "Unwatched")
        }
    }

    /// A plain eye while nothing's selected, filled once Watched is picked,
    /// slashed ("line-through") once Unwatched is picked — same idea as
    /// `favoriteStatusSystemImage`.
    private var watchStatusSystemImage: String {
        switch viewModel?.selectedWatchStatus {
        case nil: "eye"
        case .watched: "eye.fill"
        case .unwatched: "eye.slash"
        }
    }

    private func favoriteStatusLabel(_ status: CollectionFavoriteStatus) -> String {
        switch status {
        case .favorite: String(localized: "Favorites")
        case .nonFavorite: String(localized: "Non-Favorites")
        }
    }

    /// A filled heart once Favorites is picked, a slashed heart once
    /// Non-Favorites is picked (SF Symbols' stand-in for "line-through" on a
    /// glyph shape, since there's no literal strikethrough heart), and a
    /// plain outline heart while nothing's selected — same "the icon itself
    /// carries which state is active" idea as `watchStatusSystemImage`.
    private var favoriteStatusSystemImage: String {
        switch viewModel?.selectedFavoriteStatus {
        case .favorite: "heart.fill"
        case .nonFavorite: "heart.slash"
        case nil: "heart"
        }
    }

    /// Jellyfin has no separate "Network" field — a show's originating
    /// network is stored in the very same `Studios` field a movie's
    /// production studio is, so what this pill labels itself as depends on
    /// what kind of collection `query` actually is.
    private var studioFilterTitle: String {
        query.includeItemTypes.contains("Series") ? String(localized: "Network") : String(localized: "Studio")
    }

    private var studioFilterAllLabel: String {
        query.includeItemTypes.contains("Series") ? String(localized: "All Networks") : String(localized: "All Studios")
    }

    private var genreBinding: Binding<String?> {
        Binding(get: { viewModel?.selectedGenre }, set: { viewModel?.setGenreFilter($0) })
    }

    private var studioBinding: Binding<String?> {
        Binding(get: { viewModel?.selectedStudio }, set: { viewModel?.setStudioFilter($0) })
    }

    private var decadeBinding: Binding<Int?> {
        Binding(get: { viewModel?.selectedDecade }, set: { viewModel?.setDecadeFilter($0) })
    }

    private var watchStatusBinding: Binding<CollectionWatchStatus?> {
        Binding(get: { viewModel?.selectedWatchStatus }, set: { viewModel?.setWatchStatusFilter($0) })
    }

    private var favoriteStatusBinding: Binding<CollectionFavoriteStatus?> {
        Binding(get: { viewModel?.selectedFavoriteStatus }, set: { viewModel?.setFavoriteStatusFilter($0) })
    }

    @ViewBuilder
    private func content(containerWidth: CGFloat) -> some View {
        // Only short-circuits the "nothing to show yet" states — see
        // HomeView's equivalent check for why already-loaded content must
        // never be blanked out by a stale/background offline flag.
        if ConnectivityMonitor.shared.isOffline, viewModel?.loadState != .loaded {
            OfflineStateView(retry: { Task { await viewModel?.load() } })
                .frame(minHeight: 300)
        } else {
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
                    VStack(alignment: .leading, spacing: 16) {
                        filterRow

                        let filtered = viewModel?.filteredItems ?? []
                        if filtered.isEmpty {
                            ErrorStateView(message: String(localized: "No items match these filters."), retry: nil)
                                .frame(minHeight: 200)
                        } else {
                            let metrics = PosterGridMetrics(containerWidth: containerWidth)
                            LazyVGrid(columns: metrics.columns, spacing: 20) {
                                ForEach(filtered) { item in
                                    PosterCard(item: item, width: metrics.itemWidth)
                                }
                            }
                        }
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

/// One filter facet's pill button + dropdown — generic over the value type
/// (`String` for Genre/Studio, `Int` for Decade's start year). `title`/
/// `allLabel` are pre-resolved `String`s (via `String(localized:)` at the
/// call site) rather than `LocalizedStringKey`, since a literal argument to
/// a custom `String`-typed parameter here doesn't get auto-extracted by
/// Xcode the way a literal directly in `Text`/`Picker` does.
private struct FilterMenu<Value: Hashable>: View {
    let title: String
    let allLabel: String
    let options: [Value]
    let display: (Value) -> String
    /// Optional leading SF Symbol, shown alongside the pill's label whether
    /// or not a value is selected — every facet has one, so each pill reads
    /// at a glance even collapsed to its default title. All five vary the
    /// glyph by selection state (an outline while "All ___" is in effect,
    /// filled once something's actually picked — see `genreSystemImage`/
    /// `studioSystemImage`/`decadeSystemImage`), and Watched/Favorites go
    /// further still with a third, "excluded" glyph (`eye.slash`/
    /// `heart.slash`) for their negative selection.
    var systemImage: String?
    @Binding var selection: Value?

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                Text(allLabel).tag(Value?.none)
                ForEach(options, id: \.self) { option in
                    Text(display(option)).tag(Value?.some(option))
                }
            }
        } label: {
            FilterPill(label: selection.map(display) ?? title, isActive: selection != nil, systemImage: systemImage)
        }
    }
}

private struct FilterPill: View {
    let label: String
    let isActive: Bool
    /// Optional leading SF Symbol — see `FilterMenu.systemImage`'s doc
    /// comment for what each facet passes. Only `ResetFiltersButton` (which
    /// doesn't use `FilterPill` at all) leaves this `nil`.
    var systemImage: String?

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                // Tinted glass signals "active" the same way the flat
                // brand-color fill did below — plain `.regular` (no tint)
                // for the default state lets the native frosted/refractive
                // material show through instead. `.interactive()` on both
                // gives the tap the native glass press feedback, matching
                // that this pill really does open a menu.
                .glassEffect(
                    isActive ? .regular.tint(.dionysusPrimary).interactive() : .regular.interactive(), in: Capsule()
                )
        } else {
            content
                .background(isActive ? Color.dionysusPrimary : Color(.secondarySystemBackground))
                .clipShape(Capsule())
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(label)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        // Without this, the icon+text pair can get compressed below its
        // ideal width when the parent negotiates space (seen on the
        // Watched pill once it grew an icon: "Watched" truncated to
        // "Watc…" inside the horizontally-scrolling filter row even though
        // nothing was actually visually out of room) — `.fixedSize()` pins
        // the pill to its natural, uncompressed size regardless of what the
        // surrounding `ScrollView`/`GlassEffectContainer` proposes.
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.white : Color.primary)
    }
}

/// A separate, visually distinct circular icon button for clearing every
/// active filter at once — see `filterRow`'s doc comment for why this
/// isn't just another `FilterPill`.
private struct ResetFiltersButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if #available(iOS 26.0, *) {
                icon.glassEffect(.regular.interactive(), in: Circle())
            } else {
                icon
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }

    private var icon: some View {
        Label("Reset", systemImage: "xmark")
            .labelStyle(.iconOnly)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(9)
    }
}

#Preview {
    NavigationStack {
        CollectionGridView(query: CollectionQuery(title: "Movies", includeItemTypes: ["Movie"]))
    }
    .environment(AppState())
}
