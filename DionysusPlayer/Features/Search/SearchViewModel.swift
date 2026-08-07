import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    enum LoadState: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    var query = ""
    private(set) var results: [MediaItem] = []
    private(set) var loadState: LoadState = .idle

    private let client: JellyfinAPIClient
    private let userID: String
    private var searchTask: Task<Void, Never>?

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// Call whenever `query` changes; debounces so we don't hit the server
    /// on every keystroke.
    func queryChanged() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            loadState = .idle
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search(term: term)
        }
    }

    private func search(term: String) async {
        loadState = .searching
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.search(userID: userID, term: term)
            guard !Task.isCancelled else { return }
            results = result.items.map { MediaItem(dto: $0, images: images) }
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "Search failed."))
        }
    }
}
