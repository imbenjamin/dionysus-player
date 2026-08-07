import SwiftUI
import UIKit

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

    /// A row of pill buttons, one per facet that actually has values to
    /// offer (a facet with nothing available — e.g. no Studios data at
    /// all — doesn't show a dead control). Each pill opens a `Menu`
    /// listing that facet's values, letting the user narrow the grid down
    /// by one value per facet at a time (not multi-select within a facet),
    /// combined with AND across facets in `CollectionGridViewModel
    /// .filteredItems`. Reset sits *outside* the scrolling pills, anchored
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

        if !genres.isEmpty || !studios.isEmpty || !decades.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    if #available(iOS 26.0, *) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                filterPills(genres: genres, studios: studios, decades: decades)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            filterPills(genres: genres, studios: studios, decades: decades)
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
    private func filterPills(genres: [String], studios: [String], decades: [Int]) -> some View {
        if !genres.isEmpty {
            FilterMenu(
                title: String(localized: "Genre"), allLabel: String(localized: "All Genres"),
                options: genres, display: { $0 }, selection: genreBinding
            )
        }
        if !studios.isEmpty {
            FilterMenu(
                title: studioFilterTitle, allLabel: studioFilterAllLabel,
                options: studios, display: { $0 }, selection: studioBinding
            )
        }
        if !decades.isEmpty {
            FilterMenu(
                title: String(localized: "Decade"), allLabel: String(localized: "All Decades"),
                options: decades, display: { "\($0)s" }, selection: decadeBinding
            )
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
            FilterPill(label: selection.map(display) ?? title, isActive: selection != nil)
        }
    }
}

private struct FilterPill: View {
    let label: String
    let isActive: Bool

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
        Text(label)
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.white : Color.primary)
    }
}

/// A separate, visually distinct circular icon button for clearing all
/// three filters at once — see `filterRow`'s doc comment for why this
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
