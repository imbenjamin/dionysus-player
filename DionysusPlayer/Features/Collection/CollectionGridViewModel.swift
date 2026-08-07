import Foundation
import Observation

@MainActor
@Observable
final class CollectionGridViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var items: [MediaItem] = []
    private(set) var loadState: LoadState = .idle
    private(set) var sortField: CollectionSortField = .title
    private(set) var sortOrder: CollectionSortOrder = .ascending
    private(set) var selectedGenre: String?
    private(set) var selectedStudio: String?
    /// A decade's start year (e.g. `2010`), matching `MediaItem.decade`.
    private(set) var selectedDecade: Int?
    private(set) var selectedWatchStatus: CollectionWatchStatus?
    /// Unlike the other filters, this is a plain toggle rather than an
    /// `Optional` selection — there's no third "unfavorited only" state
    /// worth exposing.
    private(set) var isFavoritesOnly = false

    private let client: JellyfinAPIClient
    private let userID: String
    let query: CollectionQuery

    /// Distinct genres among items matching the *other two* active filters
    /// (not genre's own — see `matchingItems`), sorted alphabetically — the
    /// options `CollectionGridView`'s Genres filter pill offers. Narrows as
    /// Studio/Decade get picked and widens back out as they're cleared, so
    /// the pill only ever offers genres that actually lead somewhere given
    /// whatever else is currently selected, rather than options that would
    /// combine into an empty result. Client-side (not a fresh server query)
    /// since `items` is already the complete result set for this
    /// collection, not a paginated slice.
    var availableGenres: [String] {
        Array(Set(matchingItems(applyGenre: false, applyStudio: true, applyDecade: true).flatMap(\.genres))).sorted()
    }

    var availableStudios: [String] {
        Array(Set(matchingItems(applyGenre: true, applyStudio: false, applyDecade: true).flatMap(\.studios))).sorted()
    }

    /// Newest first (matches how someone scanning a library by decade
    /// typically wants to start).
    var availableDecades: [Int] {
        Array(Set(matchingItems(applyGenre: true, applyStudio: true, applyDecade: false).compactMap(\.decade)))
            .sorted(by: >)
    }

    /// Which of `.watched`/`.unwatched` actually occur among items matching
    /// the *other* active filters — same cascading logic as the other
    /// facets, just over a fixed two-value domain instead of data-derived
    /// strings/ints. `CollectionGridView` only shows this pill at all when
    /// this comes back non-empty (both possible values collapse to empty
    /// only when there are no items left at all, same as any other facet).
    var availableWatchStatuses: [CollectionWatchStatus] {
        let candidates = matchingItems(applyGenre: true, applyStudio: true, applyDecade: true, applyWatchStatus: false)
        var result: [CollectionWatchStatus] = []
        if candidates.contains(where: \.isPlayed) { result.append(.watched) }
        if candidates.contains(where: { !$0.isPlayed }) { result.append(.unwatched) }
        return result
    }

    /// Whether at least one favorite exists among items matching the other
    /// active filters — `CollectionGridView` only shows the Favorites toggle
    /// while this (or `isFavoritesOnly` itself, so an already-active toggle
    /// doesn't vanish out from under the user) is true.
    var hasAvailableFavorites: Bool {
        matchingItems(applyGenre: true, applyStudio: true, applyDecade: true, applyFavorites: false)
            .contains(where: \.isFavorite)
    }

    /// `items` narrowed by every active filter (AND across all of them) —
    /// what `CollectionGridView`'s grid actually renders, and the pool
    /// `randomItem()` picks from.
    var filteredItems: [MediaItem] {
        matchingItems(applyGenre: true, applyStudio: true, applyDecade: true)
    }

    /// A uniformly-random pick from `filteredItems`, for the toolbar's dice
    /// button — `nil` only when nothing currently matches (button is
    /// disabled in that case).
    func randomItem() -> MediaItem? {
        filteredItems.randomElement()
    }

    /// Shared machinery behind `filteredItems` (every filter applied) and
    /// each `available*` property (every filter *except its own facet*
    /// applied — computing a facet's own option list against its own
    /// current selection would trivially collapse it to just that one
    /// value). Because every facet's list is always computed from whichever
    /// of the *other* facets are currently selected, anything it offers is
    /// guaranteed compatible with the current selections — the user can
    /// never pick a combination that leads to zero results, and nothing
    /// needs to reactively invalidate/clear a stale selection when another
    /// filter changes: unreachable options simply never appear as choices
    /// in the first place. Since these are all plain computed properties
    /// over `items` and the `selected*`/`isFavoritesOnly` state, clearing
    /// any filter automatically widens the others back out too — no
    /// separate "unfilter" handling needed.
    private func matchingItems(
        applyGenre: Bool, applyStudio: Bool, applyDecade: Bool,
        applyWatchStatus: Bool = true, applyFavorites: Bool = true
    ) -> [MediaItem] {
        items.filter { item in
            (!applyGenre || selectedGenre == nil || item.genres.contains(selectedGenre!))
                && (!applyStudio || selectedStudio == nil || item.studios.contains(selectedStudio!))
                && (!applyDecade || selectedDecade == nil || item.decade == selectedDecade)
                && (!applyWatchStatus || selectedWatchStatus == nil
                    || item.isPlayed == (selectedWatchStatus == .watched))
                && (!applyFavorites || !isFavoritesOnly || item.isFavorite)
        }
    }

    /// Whether `CollectionGridView` should show its "Reset" control.
    var hasActiveFilters: Bool {
        selectedGenre != nil || selectedStudio != nil || selectedDecade != nil
            || selectedWatchStatus != nil || isFavoritesOnly
    }

    init(client: JellyfinAPIClient, userID: String, query: CollectionQuery) {
        self.client = client
        self.userID = userID
        self.query = query
    }

    func loadIfNeeded() async {
        guard items.isEmpty else { return }
        await load()
    }

    /// Changes which field the grid is ordered by and reloads — a no-op if
    /// `field` is already selected, so re-picking the current one from the
    /// toolbar menu doesn't refetch.
    func setSortField(_ field: CollectionSortField) async {
        guard field != sortField else { return }
        sortField = field
        await load()
    }

    /// Flips ascending/descending for whichever `sortField` is currently
    /// selected, and reloads — same no-op-if-unchanged behavior as
    /// `setSortField`.
    func setSortOrder(_ order: CollectionSortOrder) async {
        guard order != sortOrder else { return }
        sortOrder = order
        await load()
    }

    /// Unlike sort, these filter `items` locally (`filteredItems`) rather
    /// than reloading from the server — no network round trip needed, and
    /// they compose freely with whatever sort is active.
    func setGenreFilter(_ genre: String?) {
        selectedGenre = genre
    }

    func setStudioFilter(_ studio: String?) {
        selectedStudio = studio
    }

    func setDecadeFilter(_ decade: Int?) {
        selectedDecade = decade
    }

    func setWatchStatusFilter(_ status: CollectionWatchStatus?) {
        selectedWatchStatus = status
    }

    func setFavoritesOnly(_ isFavoritesOnly: Bool) {
        self.isFavoritesOnly = isFavoritesOnly
    }

    /// Clears every active filter at once — `CollectionGridView`'s Reset
    /// control, shown only while `hasActiveFilters` is true.
    func resetFilters() {
        selectedGenre = nil
        selectedStudio = nil
        selectedDecade = nil
        selectedWatchStatus = nil
        isFavoritesOnly = false
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.items(
                userID: userID,
                parentID: query.parentID,
                includeItemTypes: query.includeItemTypes,
                sortBy: sortField.sortBy,
                sortOrder: sortOrder.value
            )
            items = result.items.map { MediaItem(dto: $0, images: images) }
            loadState = .loaded
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't load this collection.")
            )
        }
    }
}
