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

    /// Drops an item deleted from the server, so the user doesn't pop back from a
    /// detail page onto a tile for content that's gone. Called by
    /// `CollectionGridView` off `DeletedItemBroadcaster`. A local filter rather
    /// than a refetch: nothing else changed, and every facet's option list derives
    /// from `items`.
    func removeDeletedItem(itemID: String) {
        items.removeAll { $0.id == itemID }
    }
    private(set) var loadState: LoadState = .idle
    /// Seeded from `query.initialSortField`/`initialSortOrder` in `init` (see
    /// `CollectionQuery`), then user-changeable via
    /// `setSortField`/`setSortOrder`.
    private(set) var sortField: CollectionSortField
    private(set) var sortOrder: CollectionSortOrder
    /// Seeded from `query.initialGenre`/`initialStudio` in `init`, as
    /// `sortField`/`sortOrder` are.
    private(set) var selectedGenre: String?
    private(set) var selectedStudio: String?
    /// A decade's start year (e.g. `2010`), matching `MediaItem.decade`.
    private(set) var selectedDecade: Int?
    private(set) var selectedWatchStatus: CollectionWatchStatus?
    private(set) var selectedFavoriteStatus: CollectionFavoriteStatus?

    private let client: JellyfinAPIClient
    private let userID: String
    let query: CollectionQuery

    /// Distinct genres among items matching every other active filter but genre's
    /// own (see `matchingItems`), sorted alphabetically — what
    /// `CollectionGridView`'s Genres pill offers. Narrows as other facets are
    /// picked and widens as they're cleared, so it never offers a combination
    /// that would come back empty. Client-side, since `items` is the complete
    /// result set rather than a paginated slice.
    var availableGenres: [String] {
        Array(Set(matchingItems(applyGenre: false, applyStudio: true, applyDecade: true).flatMap(\.genres))).sorted()
    }

    var availableStudios: [String] {
        Array(Set(matchingItems(applyGenre: true, applyStudio: false, applyDecade: true).flatMap(\.studios))).sorted()
    }

    /// Newest first, how someone scanning a library by decade usually starts.
    var availableDecades: [Int] {
        Array(Set(matchingItems(applyGenre: true, applyStudio: true, applyDecade: false).compactMap(\.decade)))
            .sorted(by: >)
    }

    /// Which of `.watched`/`.unwatched` occur among items matching the other
    /// active filters — the same cascading logic as the other facets, over a
    /// fixed two-value domain. `CollectionGridView` shows the pill only when this
    /// is non-empty, which happens only when no items are left at all.
    var availableWatchStatuses: [CollectionWatchStatus] {
        let candidates = matchingItems(applyGenre: true, applyStudio: true, applyDecade: true, applyWatchStatus: false)
        var result: [CollectionWatchStatus] = []
        if candidates.contains(where: \.isPlayed) { result.append(.watched) }
        if candidates.contains(where: { !$0.isPlayed }) { result.append(.unwatched) }
        return result
    }

    /// Which of `.favorite`/`.nonFavorite` occur among items matching the other
    /// active filters, as `availableWatchStatuses` does. `CollectionGridView`
    /// shows the pill only when this is non-empty.
    var availableFavoriteStatuses: [CollectionFavoriteStatus] {
        let candidates = matchingItems(applyGenre: true, applyStudio: true, applyDecade: true, applyFavorites: false)
        var result: [CollectionFavoriteStatus] = []
        if candidates.contains(where: \.isFavorite) { result.append(.favorite) }
        if candidates.contains(where: { !$0.isFavorite }) { result.append(.nonFavorite) }
        return result
    }

    /// `items` narrowed by every active filter, ANDed: what the grid renders and
    /// the pool `randomItem()` picks from.
    var filteredItems: [MediaItem] {
        matchingItems(applyGenre: true, applyStudio: true, applyDecade: true)
    }

    /// A uniformly-random pick from `filteredItems` for the toolbar's dice
    /// button; `nil` when nothing matches, where the button is disabled.
    func randomItem() -> MediaItem? {
        filteredItems.randomElement()
    }

    /// Shared machinery behind `filteredItems`, which applies every filter, and
    /// each `available*` property, which applies every filter but its own facet —
    /// computing a facet's options against its own selection would collapse it to
    /// that one value.
    ///
    /// Because every facet's list comes from the other facets' current
    /// selections, anything it offers is compatible with them: the user can't
    /// reach a zero-result combination, and no stale selection needs
    /// invalidating, since unreachable options never appear. These are plain
    /// computed properties over `items` and the `selected*` state, so clearing
    /// any filter widens the others back out with no separate handling.
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
                && (!applyFavorites || selectedFavoriteStatus == nil
                    || item.isFavorite == (selectedFavoriteStatus == .favorite))
        }
    }

    /// Whether `CollectionGridView` should show its "Reset" control.
    var hasActiveFilters: Bool {
        selectedGenre != nil || selectedStudio != nil || selectedDecade != nil
            || selectedWatchStatus != nil || selectedFavoriteStatus != nil
    }

    init(client: JellyfinAPIClient, userID: String, query: CollectionQuery) {
        self.client = client
        self.userID = userID
        self.query = query
        self.sortField = query.initialSortField
        self.sortOrder = query.initialSortOrder
        self.selectedGenre = query.initialGenre
        self.selectedStudio = query.initialStudio
    }

    func loadIfNeeded() async {
        guard items.isEmpty else { return }
        await load()
    }

    /// Changes which field the grid is ordered by and reloads; a no-op if `field`
    /// is already selected, so re-picking it doesn't refetch.
    func setSortField(_ field: CollectionSortField) async {
        guard field != sortField else { return }
        sortField = field
        await load()
    }

    /// Flips ascending/descending for the selected `sortField` and reloads, with
    /// the same no-op-if-unchanged behavior as `setSortField`.
    func setSortOrder(_ order: CollectionSortOrder) async {
        guard order != sortOrder else { return }
        sortOrder = order
        await load()
    }

    /// Unlike sort, these filter `items` locally via `filteredItems` rather than
    /// reloading, so they need no round trip and compose with any active sort.
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

    func setFavoriteStatusFilter(_ status: CollectionFavoriteStatus?) {
        selectedFavoriteStatus = status
    }

    /// Clears every active filter: `CollectionGridView`'s Reset control, shown
    /// only while `hasActiveFilters` is true.
    func resetFilters() {
        selectedGenre = nil
        selectedStudio = nil
        selectedDecade = nil
        selectedWatchStatus = nil
        selectedFavoriteStatus = nil
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            // AUDIO SUPPRESSION: `excludeItemTypes` keeps audio out of every grid
            // this view model loads, however its `CollectionQuery` was scoped —
            // see `JellyfinAPIClient.audioItemTypeExclusions`. Delete once audio
            // playback is supported.
            let result = try await client.items(
                userID: userID,
                parentID: query.parentID,
                includeItemTypes: query.includeItemTypes,
                excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions,
                sortBy: sortField.sortBy,
                sortOrder: sortOrder.value
            )
            items = result.items.map { MediaItem(dto: $0, images: images) }
            // AUDIO SUPPRESSION: `"Playlist"` is excluded from
            // `audioItemTypeExclusions` above, since a Playlists query returns the
            // Playlist entries rather than their members and item type can't
            // filter a mixed one. Filtered client-side instead, as
            // `BaseItemDto.isAudioContent` does per item: an audio-only or empty
            // playlist is dropped, a mixed one passes through. Delete once audio
            // playback is supported.
            if query.includeItemTypes.contains("Playlist") {
                items = items.filter { !$0.isAudioContent }
            }
            loadState = .loaded
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't load this collection.")
            )
        }
    }
}
