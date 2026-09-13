import SwiftUI
import UIKit

/// A grid of a collection's items — a library (all Movies), a BoxSet, or
/// any other parent/filter combination described by a `CollectionQuery`.
struct CollectionGridView: View {
    let query: CollectionQuery

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: CollectionGridViewModel?
    /// Drives the dice button's push. A local `MediaItem?` binding rather than
    /// `AppRoute`/`.navigationDestination(for:)`, already registered in
    /// `MainTabView`'s `NavigationStack`: a second `navigationDestination` for
    /// the same type nested inside that stack is ambiguous per SwiftUI's docs.
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
            // On iOS 26 adjacent trailing items share one Liquid Glass
            // background whether or not they're in a `ToolbarItemGroup`, and
            // separate `ToolbarItem`s alone don't break that. `ToolbarSpacer(
            // .fixed)` is the API for splitting them into separate capsules, as
            // sort and random are unrelated actions. No pre-26 fallback needed:
            // adjacent items weren't fused before then.
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) { randomButton }
        }
        .task { await setUpIfNeeded() }
        // An item deleted from its detail page shouldn't still have a tile here
        // when the user pops back. See `DeletedItemBroadcaster`.
        .onChange(of: DeletedItemBroadcaster.shared.token) {
            guard let itemID = DeletedItemBroadcaster.shared.lastDeletedItemID else { return }
            viewModel?.removeDeletedItem(itemID: itemID)
        }
    }

    /// Jumps to a uniformly-random item from whatever is currently filtered into
    /// view. Disabled when there's nothing to pick from.
    private var randomButton: some View {
        Button {
            randomPick = viewModel?.randomItem()
        } label: {
            Image(systemName: "dice")
        }
        .disabled((viewModel?.filteredItems ?? []).isEmpty)
        .accessibilityLabel(String(localized: "Random Item"))
        .accessibilityIdentifier(A11yID.Collection.randomButton)
    }

    /// Mirrors `AppRouteDestinationView`'s `.assetDetail` branch, kept local
    /// rather than routed through `AppRoute` — see `randomPick`.
    @ViewBuilder
    private func randomDestination(for item: MediaItem) -> some View {
        if let client = appState.apiClient,
           let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID {
            AssetDetailView(itemID: item.id, preloadedItem: item, client: client, userID: userID)
        } else {
            ErrorStateView(message: String(localized: "You're not signed in."), retry: nil)
        }
    }

    /// Two independent `Picker` groups in one `Menu`: field and direction are
    /// separate axes, so any field can go either way. Always shown regardless of
    /// load state, so an ordering can be chosen before or during a failed load.
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
        .accessibilityLabel(String(localized: "Sort Options"))
        .accessibilityIdentifier(A11yID.Collection.sortMenu)
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

    /// A row of pill buttons, one per facet with values to offer, each opening a
    /// `Menu` of that facet's values. Facets AND together in
    /// `CollectionGridViewModel.filteredItems`. Reset sits outside the scrolling
    /// pills: inside the row, as a same-shape pill, it read as a fourth filter.
    ///
    /// `ViewThatFits` prefers an `HStack` hugging its content, with Reset right
    /// after the last pill, falling back to a scrolling row with Reset pinned
    /// trailing. A `ScrollView` accepts any offered width, so the fallback wins
    /// only when the pills genuinely don't fit — iPhone, and any device at
    /// accessibility text sizes. Left to itself it claimed the full width even
    /// when the pills fit several times over, leaving a wide void between Reset
    /// and what it clears.
    ///
    /// On iOS 26+ the pills sit inside a `GlassEffectContainer`, required so
    /// adjacent `.glassEffect` shapes blend as one material rather than each
    /// rendering its own pass. Pre-26 falls back to `FilterPill`'s flat colour.
    ///
    /// `.scrollClipDisabled()` stops the scroll view clipping each pill's glass
    /// and shadow at its pill-tight bounds, but it disables clipping on every
    /// edge, so a scrolled pill drew over the Reset button. The `.mask` — the
    /// row's bounds widened top and bottom by negative vertical padding — puts
    /// the horizontal clipping back.
    @ViewBuilder
    private var filterRow: some View {
        let genres = viewModel?.availableGenres ?? []
        let studios = viewModel?.availableStudios ?? []
        let decades = viewModel?.availableDecades ?? []
        let watchStatuses = viewModel?.availableWatchStatuses ?? []
        let favoriteStatuses = viewModel?.availableFavoriteStatuses ?? []

        if !genres.isEmpty || !studios.isEmpty || !decades.isEmpty || !watchStatuses.isEmpty || !favoriteStatuses.isEmpty {
            let pills = pillRow(
                genres: genres, studios: studios, decades: decades,
                watchStatuses: watchStatuses, favoriteStatuses: favoriteStatuses
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pills
                    resetButton
                }

                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) { pills }
                        .scrollClipDisabled()
                        .mask(Rectangle().padding(.vertical, -16))
                    resetButton
                }
            }
        }
    }

    @ViewBuilder
    private var resetButton: some View {
        if viewModel?.hasActiveFilters == true {
            ResetFiltersButton { viewModel?.resetFilters() }
                .accessibilityIdentifier(A11yID.Collection.resetFiltersButton)
        }
    }

    /// The pills themselves, shared by both of `filterRow`'s arrangements.
    @ViewBuilder
    private func pillRow(
        genres: [String], studios: [String], decades: [Int],
        watchStatuses: [CollectionWatchStatus], favoriteStatuses: [CollectionFavoriteStatus]
    ) -> some View {
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
            .accessibilityIdentifier(A11yID.Collection.filterPill("genre"))
        }
        if !studios.isEmpty {
            FilterMenu(
                title: studioFilterTitle, allLabel: studioFilterAllLabel,
                options: studios, display: { $0 }, systemImage: studioSystemImage, selection: studioBinding
            )
            .accessibilityIdentifier(A11yID.Collection.filterPill("studio"))
        }
        if !decades.isEmpty {
            FilterMenu(
                title: String(localized: "Decade"), allLabel: String(localized: "All Decades"),
                options: decades, display: { "\($0)s" }, systemImage: decadeSystemImage, selection: decadeBinding
            )
            .accessibilityIdentifier(A11yID.Collection.filterPill("decade"))
        }
        if !watchStatuses.isEmpty {
            FilterMenu(
                title: String(localized: "Watched"), allLabel: String(localized: "All"),
                options: watchStatuses, display: watchStatusLabel,
                systemImage: watchStatusSystemImage, selection: watchStatusBinding
            )
            .accessibilityIdentifier(A11yID.Collection.filterPill("watched"))
        }
        if !favoriteStatuses.isEmpty {
            FilterMenu(
                title: String(localized: "Favorites"), allLabel: String(localized: "All Items"),
                options: favoriteStatuses, display: favoriteStatusLabel,
                systemImage: favoriteStatusSystemImage, selection: favoriteStatusBinding
            )
            .accessibilityIdentifier(A11yID.Collection.filterPill("favorites"))
        }
    }

    /// Outline while "All Genres" is in effect, filled once a genre is picked —
    /// the same active-by-fill convention as `FilterPill`'s glass tint.
    /// `studioSystemImage`/`decadeSystemImage` mirror it.
    private var genreSystemImage: String {
        viewModel?.selectedGenre == nil ? "theatermasks" : "theatermasks.fill"
    }

    private var studioSystemImage: String {
        viewModel?.selectedStudio == nil ? "building.2" : "building.2.fill"
    }

    /// `clock`/`clock.fill` rather than `calendar`: SF Symbols has no
    /// `calendar.fill` to switch to once a decade is selected.
    private var decadeSystemImage: String {
        viewModel?.selectedDecade == nil ? "clock" : "clock.fill"
    }

    private func watchStatusLabel(_ status: CollectionWatchStatus) -> String {
        switch status {
        case .watched: String(localized: "Watched")
        case .unwatched: String(localized: "Unwatched")
        }
    }

    /// A plain eye while nothing's selected, filled for Watched, slashed for
    /// Unwatched — as in `favoriteStatusSystemImage`.
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

    /// A filled heart for Favorites, a slashed one for Non-Favorites (SF
    /// Symbols' stand-in for a strikethrough), a plain outline while nothing's
    /// selected — as in `watchStatusSystemImage`.
    private var favoriteStatusSystemImage: String {
        switch viewModel?.selectedFavoriteStatus {
        case .favorite: "heart.fill"
        case .nonFavorite: "heart.slash"
        case nil: "heart"
        }
    }

    /// Jellyfin has no separate "Network" field: a show's network lives in the
    /// same `Studios` field a movie's studio does, so the pill's label depends
    /// on what kind of collection `query` is.
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
        // Only short-circuits the "nothing to show yet" states; see `HomeView`'s
        // equivalent for why loaded content must not be blanked by a stale
        // offline flag.
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
                        .accessibilityIdentifier(A11yID.Collection.emptyState)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        filterRow

                        let filtered = viewModel?.filteredItems ?? []
                        if filtered.isEmpty {
                            // A distinct identifier from `emptyState`: the
                            // cascading-facet guarantee makes this branch
                            // unreachable through the UI, and a test asserting
                            // that must tell it from a genuinely empty library.
                            ErrorStateView(message: String(localized: "No items match these filters."), retry: nil)
                                .frame(minHeight: 200)
                                .accessibilityIdentifier(A11yID.Collection.noFilterMatches)
                        } else {
                            // The same larger iPad target `SearchView`'s grid
                            // and `MediaRailView`'s cards use. On
                            // `PosterGridMetrics`' iPhone-oriented 130pt default
                            // the same poster measured 160pt in a Home rail and
                            // ~178pt in Search, but 144.5/150.5pt here — smaller
                            // on the screen dedicated to browsing it. Costs a
                            // column (portrait 5 -> 4, landscape 7 -> 6) and buys
                            // back the card label, which at accessibility text
                            // sizes truncated the subtitle mid-value
                            // ("2007 · 2h…"). Compact width is unchanged: at
                            // 393pt the 3-column floor wins either way.
                            let metrics = PosterGridMetrics(
                                containerWidth: containerWidth,
                                idealItemWidth: horizontalSizeClass == .regular ? 160 : PosterGridMetrics.idealItemWidth
                            )
                            LazyVGrid(columns: metrics.columns, spacing: 20) {
                                ForEach(filtered) { item in
                                    PosterCard(item: item, width: metrics.itemWidth)
                                }
                            }
                            .accessibilityIdentifier(A11yID.Collection.grid)
                        }
                    }
                }
            }
        }
    }

    private func setUpIfNeeded() async {
        // Falls back to the cached `userID` from a prior sign-in, so a cold
        // launch that resumed `.main` from cache still builds a view model right
        // away. See `AppState.start()`.
        guard viewModel == nil, let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let newViewModel = CollectionGridViewModel(client: client, userID: userID, query: query)
        viewModel = newViewModel
        await newViewModel.loadIfNeeded()
    }
}

/// One filter facet's pill button and dropdown, generic over the value type
/// (`String` for Genre/Studio, `Int` for Decade's start year). `title` and
/// `allLabel` are pre-resolved `String`s via `String(localized:)` at the call
/// site, since a literal passed to a custom `String`-typed parameter isn't
/// auto-extracted the way one directly in `Text`/`Picker` is.
private struct FilterMenu<Value: Hashable>: View {
    let title: String
    let allLabel: String
    let options: [Value]
    let display: (Value) -> String
    /// Leading SF Symbol, shown whether or not a value is selected, so each pill
    /// reads at a glance collapsed to its default title. All five vary the glyph
    /// by selection state — outline while "All ___" is in effect, filled once
    /// something is picked — and Watched/Favorites add a third, excluded glyph
    /// (`eye.slash`/`heart.slash`) for their negative selection.
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
    /// Leading SF Symbol; see `FilterMenu.systemImage` for what each facet
    /// passes. Only `ResetFiltersButton`, which doesn't use `FilterPill`, leaves
    /// it `nil`.
    var systemImage: String?

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    // Tinted glass signals active, as the flat brand-color fill
                    // below does; untinted `.regular` lets the native frosted
                    // material show through for the default state.
                    // `.interactive()` gives both the native press feedback.
                    .glassEffect(
                        isActive ? .regular.tint(.dionysusPrimary).interactive() : .regular.interactive(), in: Capsule()
                    )
            } else {
                content
                    .background(isActive ? Color.dionysusPrimary : Color(.secondarySystemBackground))
                    .clipShape(Capsule())
            }
        }
        // The pill's compact chrome (`padding(.vertical, 6)` in `content`)
        // renders ~27pt tall, under HIG's 44pt minimum and even its 28pt floor.
        // Padding the tap frame rather than the pill keeps the compact look in a
        // scrolling row while meeting the minimum — the same visual-size-versus-
        // tap-size split as `PlayerControlsOverlay`'s badges.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
        // Without this the icon and text get compressed below their ideal width
        // when the parent negotiates space: the Watched pill truncated to
        // "Watc…" inside the scrolling row with nothing visually out of room.
        // `.fixedSize()` pins the pill to its natural size whatever the
        // surrounding `ScrollView`/`GlassEffectContainer` proposes.
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.white : Color.primary)
    }
}

/// A visually distinct circular button clearing every active filter at once —
/// see `filterRow` for why it isn't another `FilterPill`.
private struct ResetFiltersButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if #available(iOS 26.0, *) {
                    icon.glassEffect(.regular.interactive(), in: Circle())
                } else {
                    icon
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
            }
            // Same HIG 44pt tap-target padding as `FilterPill`: the visible
            // circle stays at `icon`'s `.padding(9)` (~31pt) while an invisible
            // frame pads the tap area to the minimum.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
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
