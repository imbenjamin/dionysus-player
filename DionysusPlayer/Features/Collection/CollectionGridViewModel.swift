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

    private let client: JellyfinAPIClient
    private let userID: String
    let query: CollectionQuery

    /// Distinct genres across the *currently loaded* `items`, sorted
    /// alphabetically — the options `CollectionGridView`'s Genres filter
    /// pill offers. Client-side (not a fresh server query) since `items`
    /// is already the complete result set for this collection, not a
    /// paginated slice.
    var availableGenres: [String] { Array(Set(items.flatMap(\.genres))).sorted() }
    var availableStudios: [String] { Array(Set(items.flatMap(\.studios))).sorted() }
    /// Newest first (matches how someone scanning a library by decade
    /// typically wants to start).
    var availableDecades: [Int] { Array(Set(items.compactMap(\.decade))).sorted(by: >) }

    /// `items` narrowed by whichever of `selectedGenre`/`selectedStudio`/
    /// `selectedDecade` are set (AND across all three that are set) — what
    /// `CollectionGridView`'s grid actually renders.
    var filteredItems: [MediaItem] {
        items.filter { item in
            (selectedGenre == nil || item.genres.contains(selectedGenre!))
                && (selectedStudio == nil || item.studios.contains(selectedStudio!))
                && (selectedDecade == nil || item.decade == selectedDecade)
        }
    }

    /// Whether `CollectionGridView` should show its "Reset" control.
    var hasActiveFilters: Bool {
        selectedGenre != nil || selectedStudio != nil || selectedDecade != nil
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

    /// Clears all three filters at once — `CollectionGridView`'s Reset
    /// control, shown only while `hasActiveFilters` is true.
    func resetFilters() {
        selectedGenre = nil
        selectedStudio = nil
        selectedDecade = nil
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
