import SwiftUI

/// A library's page and a See All grid (prototype screen 9), on the shared
/// `CollectionGridViewModel`: a title and count, a sort pill, the five
/// cascading filter pills, six columns of posters, and an alphabet bar down
/// the right edge while sorted by title.
struct TVCollectionGridView: View {
    let title: String
    let titleIdentifier: String
    let viewModel: CollectionGridViewModel
    @Binding var rememberedItemID: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @FocusState private var focus: String?
    @Environment(\.resetFocus) private var resetFocus
    /// The page's focus scope, in which the grid is the default.
    @Namespace private var gridScope
    /// The pill whose list is open, if any.
    @State private var openPill: String?
    /// The header's height, which the grid leaves room for at its top.
    @State private var headerHeight: CGFloat = 220
    /// How far the grid has scrolled from its top.
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollToTopToken = 0
    @State private var landingToken = 0

    private var items: [MediaItem] { viewModel.filteredItems }

    var body: some View {
        TVPageScaffold {
            // Drawn whenever there are items, whatever the load state: a
            // refresh on the way back from a detail page must not blank the
            // grid and lose its place.
            if !viewModel.items.isEmpty {
                grid
            } else if case .failed(let message) = viewModel.loadState {
                TVPageMessage(title: String(localized: "Couldn't Load \(title)"), message: message, actionTitle: "Try Again", actionIdentifier: A11yID.TV.Library.retry) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.loadState == .loaded {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                .padding(.top, 60)
            } else {
                // Takes focus, so the sidebar doesn't open over it (see
                // `TVDetailLoading`).
                TVDetailLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await viewModel.loadIfNeeded() }
        // Back on show: a detail page above may have changed a tile's
        // watched or favourite state.
        .onChange(of: isOnShow) { _, onShow in
            if onShow { Task { await viewModel.load() } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text(verbatim: title).font(.title2.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier(titleIdentifier)
            Text("\(items.count) items").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier(A11yID.TV.Library.count)
        }
    }

    /// The posters are a UIKit collection view, for the system's alphabet
    /// index (`TVPosterCollection`). The header is drawn over its top and
    /// moved with its scrolling, rather than inside it, so the pills and the
    /// list they open stay in this view's own focus state.
    private var grid: some View {
        ZStack(alignment: .topLeading) {
            TVPosterCollection(
                // From every item, not the filtered ones, so a filter never
                // changes the grid's shape under the person.
                items: items, shape: TVTileShape(items: viewModel.items), showsIndex: viewModel.sortField == .title, indexDescending: viewModel.sortOrder == .descending,
                topInset: headerHeight, isLocked: openPill != nil, scrollToTopToken: scrollToTopToken, landingToken: landingToken,
                rememberedItemID: $rememberedItemID,
                onScroll: { scrollOffset = $0 },
                resetFocus: { resetFocus(in: gridScope) },
                open: { item in open(.assetDetail(itemID: item.id, preloadedItem: item)) }
            )
            .ignoresSafeArea(edges: [.bottom, .trailing])
            .prefersDefaultFocus(true, in: gridScope)

            VStack(alignment: .leading, spacing: 30) {
                header
                pills
                if items.isEmpty {
                    // Unreachable through the pills, which cascade;
                    // reachable when the server's data changes under an
                    // active filter. Reset is in the pill row.
                    Text("No items match these filters.").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 30)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .overlayPreferenceValue(TVDropdownAnchors.self) { openList($0) }
            .offset(y: -scrollOffset)
        }
        .focusScope(gridScope)
        // Scrolled, Menu first goes back to the landing view: the top, focus
        // on the first tile. At the top it's the shell's (pop or sidebar).
        // An open list's own Menu handler is nearer focus, so it closes first.
        .onExitCommand(perform: scrollOffset > 1 ? { landingToken += 1 } : nil)
        // A pill taking focus brings the page back to its top, where the
        // pills are: they scroll away with the grid, but only on screen.
        .onChange(of: focus) { _, new in
            if new?.hasPrefix("pill.") == true, scrollOffset > 1 { scrollToTopToken += 1 }
        }
    }

    private var pills: some View {
        HStack(spacing: 16) {
            ForEach(filterDropdowns) { dropdown in
                TVDropdownPill(dropdown: dropdown, openPill: $openPill, focus: $focus)
            }

            // One press clears every filter; drawn only while one is set,
            // as on iOS.
            if viewModel.hasActiveFilters {
                Button {
                    viewModel.resetFilters()
                    // Held for a moment: Reset removes itself and the grid
                    // reloads, and focus otherwise drifts into the grid.
                    let pill = filterDropdowns.first?.pillFocus ?? sortDropdown.pillFocus
                    focus = pill
                    Task { @MainActor in
                        for _ in 0..<8 {
                            try? await Task.sleep(for: .milliseconds(40))
                            if focus != pill { focus = pill }
                        }
                    }
                } label: {
                    Label("Reset", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .focused($focus, equals: TVDropdown.pillFocus("reset"))
                .accessibilityIdentifier(A11yID.TV.Library.resetFilters)
            }

            // Filters on the left, sort anchored at the right (Benjamin,
            // 2026-10-02).
            Spacer(minLength: 16)
            TVDropdownPill(dropdown: sortDropdown, openPill: $openPill, focus: $focus)
        }
        .padding(.trailing, 80)
        .focusSection()
    }

    /// The open pill's list, laid over the page beneath its pill.
    @ViewBuilder
    private func openList(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let dropdown = (filterDropdowns + [sortDropdown]).first(where: { $0.id == openPill }), let anchor = anchors[dropdown.id] {
                let pill = proxy[anchor]
                // Padding, not an offset: the focus engine goes by layout.
                TVDropdownList(dropdown: dropdown, openPill: $openPill, focus: $focus)
                    .padding(.leading, max(0, dropdown.alignsTrailing ? pill.maxX - TVDropdownList.width : pill.minX))
                    .padding(.top, pill.maxY + 18)
            }
        }
    }

    private var sortDropdown: TVDropdown {
        let fields: [(CollectionSortField, String)] = [
            (.title, String(localized: "Title")), (.dateAdded, String(localized: "Date Added")), (.releaseDate, String(localized: "Release Date"))
        ]
        let orders: [(CollectionSortOrder, String)] = [(.ascending, String(localized: "Ascending")), (.descending, String(localized: "Descending"))]
        return TVDropdown(
            id: "sort", title: sortTitle, icon: "arrow.up.arrow.down",
            sections: [
                fields.enumerated().map { index, field in
                    TVDropdownOption(id: "field\(index)", title: field.1, isSelected: viewModel.sortField == field.0) {
                        Task { await viewModel.setSortField(field.0) }
                    }
                },
                orders.enumerated().map { index, order in
                    TVDropdownOption(id: "order\(index)", title: order.1, isSelected: viewModel.sortOrder == order.0) {
                        Task { await viewModel.setSortOrder(order.0) }
                    }
                }
            ],
            alignsTrailing: true, identifier: A11yID.TV.Library.sort
        )
    }

    /// A pill is drawn only while it has something to offer, as on iOS. The
    /// options come from the view model, which applies every other active
    /// facet first, so no choice here leaves the grid empty. The symbols are
    /// iOS's (`CollectionGridView`): filled or struck while a filter is on.
    private var filterDropdowns: [TVDropdown] {
        [
            filterDropdown("genre", icon: viewModel.selectedGenre == nil ? "theatermasks" : "theatermasks.fill", title: String(localized: "Genre"), all: String(localized: "All Genres"),
                           options: viewModel.availableGenres, selection: viewModel.selectedGenre, display: { $0 }, set: viewModel.setGenreFilter),
            filterDropdown("studio", icon: viewModel.selectedStudio == nil ? "building.2" : "building.2.fill", title: studioTitle, all: studioAllTitle,
                           options: viewModel.availableStudios, selection: viewModel.selectedStudio, display: { $0 }, set: viewModel.setStudioFilter),
            // "1990s": a formatted year, not translated.
            filterDropdown("decade", icon: viewModel.selectedDecade == nil ? "clock" : "clock.fill", title: String(localized: "Decade"), all: String(localized: "All Decades"),
                           options: viewModel.availableDecades, selection: viewModel.selectedDecade, display: { "\($0)s" }, set: viewModel.setDecadeFilter),
            filterDropdown("watched", icon: watchedIcon, title: String(localized: "Watched"), all: String(localized: "All Items"),
                           options: viewModel.availableWatchStatuses, selection: viewModel.selectedWatchStatus,
                           display: { $0 == .watched ? String(localized: "Watched") : String(localized: "Unwatched") }, set: viewModel.setWatchStatusFilter),
            filterDropdown("favorites", icon: favoritesIcon, title: String(localized: "Favorites"), all: String(localized: "All Items"),
                           options: viewModel.availableFavoriteStatuses, selection: viewModel.selectedFavoriteStatus,
                           display: { $0 == .favorite ? String(localized: "Favorites") : String(localized: "Non-Favorites") }, set: viewModel.setFavoriteStatusFilter)
        ].compactMap { $0 }
    }

    private func filterDropdown<Option: Hashable>(
        _ facet: String, icon: String, title: String, all: String, options: [Option], selection: Option?,
        display: @escaping (Option) -> String, set: @escaping (Option?) -> Void
    ) -> TVDropdown? {
        guard !options.isEmpty else { return nil }
        return TVDropdown(
            id: facet, title: selection.map(display) ?? title, icon: icon,
            sections: [
                [TVDropdownOption(id: "all", title: all, isSelected: selection == nil) { set(nil) }]
                    + options.enumerated().map { index, option in
                        TVDropdownOption(id: String(index), title: display(option), isSelected: option == selection) { set(option) }
                    }
            ],
            identifier: A11yID.TV.Library.filter(facet)
        )
    }

    private var watchedIcon: String {
        switch viewModel.selectedWatchStatus {
        case nil: "eye"
        case .watched: "eye.fill"
        case .unwatched: "eye.slash"
        }
    }

    private var favoritesIcon: String {
        switch viewModel.selectedFavoriteStatus {
        case nil: "heart"
        case .favorite: "heart.fill"
        case .nonFavorite: "heart.slash"
        }
    }

    private var sortTitle: String {
        switch viewModel.sortField {
        case .title: String(localized: "Title")
        case .dateAdded: String(localized: "Date Added")
        case .releaseDate: String(localized: "Release Date")
        }
    }

    /// Jellyfin has no Network field: a show's network is in Studios.
    private var isSeries: Bool { viewModel.query.includeItemTypes.contains("Series") }
    private var studioTitle: String { isSeries ? String(localized: "Network") : String(localized: "Studio") }
    private var studioAllTitle: String { isSeries ? String(localized: "All Networks") : String(localized: "All Studios") }
}
