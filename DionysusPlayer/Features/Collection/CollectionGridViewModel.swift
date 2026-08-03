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

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.items(
                userID: userID,
                parentID: query.parentID,
                includeItemTypes: query.includeItemTypes,
                sortBy: query.sortBy,
                sortOrder: query.sortOrder
            )
            items = result.items.map { MediaItem(dto: $0, images: images) }
            loadState = .loaded
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't load this collection.")
        }
    }
}
