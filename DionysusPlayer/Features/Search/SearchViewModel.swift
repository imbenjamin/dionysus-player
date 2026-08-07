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
    /// sync locally by `recordSelection`/`removeFromHistory`/`clearHistory`
    /// rather than re-reading `UserDefaults` on every access.
    private(set) var history: [SearchResult] = []

    private let client: JellyfinAPIClient
    private let userID: String
    private let historyStore: SearchHistoryStore
    private var searchTask: Task<Void, Never>?
    /// Fetched once per instance rather than once per search — the base
    /// URL/token are effectively constant for a `SearchViewModel`'s whole
    /// lifetime (a session only gets a new one across a full re-login,
    /// which tears this ViewModel down and rebuilds it too). `nil` only
    /// briefly, between `init` and `loadImagesIfNeeded()` landing.
    private var imageURLBuilder: ImageURLBuilder?

    init(client: JellyfinAPIClient, userID: String, historyStore: SearchHistoryStore = SearchHistoryStore()) {
        self.client = client
        self.userID = userID
        self.historyStore = historyStore
        history = historyStore.history(userID: userID)
    }

    /// Call once when the view appears. Resolves `imageURLBuilder` so
    /// `imageURL(for:)` can start returning real URLs — `history` is
    /// already loaded synchronously in `init`, so this is what makes its
    /// thumbnails appear (they're blank, briefly, until this lands).
    func loadImagesIfNeeded() async {
        guard imageURLBuilder == nil else { return }
        imageURLBuilder = await client.makeImageURLBuilder()
    }

    /// Resolves a result/history entry's stable `imageReference` against
    /// the current session's `ImageURLBuilder` — see `SearchResult`'s doc
    /// comment for why this is resolved on demand here rather than stored.
    func imageURL(for result: SearchResult) -> URL? {
        guard let imageURLBuilder else { return nil }
        return result.imageURL(images: imageURLBuilder)
    }

    /// Call when the user taps through a result (live or from history) —
    /// records it as the most recent "successful" search, bumping it to
    /// the front if it's already in history.
    func recordSelection(_ result: SearchResult) {
        history = historyStore.record(result, userID: userID)
    }

    /// Removes a single history entry (e.g. a per-row swipe action), as
    /// opposed to `clearHistory`'s wipe-everything.
    func removeFromHistory(_ result: SearchResult) {
        history = historyStore.remove(id: result.id, userID: userID)
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
            let result = try await client.searchHints(userID: userID, term: term)
            guard !Task.isCancelled else { return }
            results = result.searchHints.map { SearchResult(hint: $0) }
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "Search failed."))
        }
    }
}
