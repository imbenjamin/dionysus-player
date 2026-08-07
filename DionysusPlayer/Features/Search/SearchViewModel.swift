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
    /// Sourced entirely from Jellyfin's `/Search/Hints` endpoint
    /// (`JellyfinAPIClient.searchHints`) — fast enough to serve as the
    /// actual results list, not just a typeahead dropdown, so there's no
    /// separate full-`BaseItemDto` results fetch.
    private(set) var results: [SearchResult] = []
    private(set) var loadState: LoadState = .idle
    /// Recently *selected* search results (not just past query text),
    /// most-recent-first — shown on `SearchView`'s landing page, on-device
    /// only via `SearchHistoryStore`. Loaded once at `init` and kept in
    /// sync locally by `recordSelection`/`clearHistory` rather than
    /// re-reading `UserDefaults` on every access.
    private(set) var history: [SearchResult] = []

    private let client: JellyfinAPIClient
    private let userID: String
    private let historyStore: SearchHistoryStore
    private var searchTask: Task<Void, Never>?

    init(client: JellyfinAPIClient, userID: String, historyStore: SearchHistoryStore = SearchHistoryStore()) {
        self.client = client
        self.userID = userID
        self.historyStore = historyStore
        history = historyStore.history(userID: userID)
    }

    /// Call when the user taps through a result (live or from history) —
    /// records it as the most recent "successful" search, bumping it to
    /// the front if it's already in history.
    func recordSelection(_ result: SearchResult) {
        historyStore.record(result, userID: userID)
        history = historyStore.history(userID: userID)
    }

    /// Removes a single history entry (e.g. a per-row swipe action), as
    /// opposed to `clearHistory`'s wipe-everything.
    func removeFromHistory(_ result: SearchResult) {
        historyStore.remove(id: result.id, userID: userID)
        history = historyStore.history(userID: userID)
    }

    func clearHistory() {
        historyStore.clear(userID: userID)
        history = []
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
            let result = try await client.searchHints(userID: userID, term: term)
            guard !Task.isCancelled else { return }
            results = result.searchHints.map { SearchResult(hint: $0, images: images) }
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "Search failed."))
        }
    }
}
