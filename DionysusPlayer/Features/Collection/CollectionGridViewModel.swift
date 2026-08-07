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

    private let client: JellyfinAPIClient
    private let userID: String
    let query: CollectionQuery

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
