import Foundation

/// Persists recent successful searches — a result the user selected, not what
/// they typed — so `SearchView`'s landing page offers one-tap access back.
///
/// Device-local `UserDefaults`, never round-tripped through the server, and
/// keyed by `userID` so a shared device doesn't leak one user's history to
/// another.
final class SearchHistoryStore {
    /// A handful of shortcuts back to something recently viewed, not a log.
    /// Trimmed to this many entries, most recent first.
    private static let maxEntries = 20

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(userID: String) -> String { "search.history.\(userID)" }

    func history(userID: String) -> [SearchResult] {
        guard let data = defaults.data(forKey: key(userID: userID)),
              let entries = try? decoder.decode([SearchResult].self, from: data) else { return [] }
        return entries
    }

    /// Records `result` as the most recent entry, moving an already-present one
    /// to the front rather than duplicating it. Returns the resulting list, so
    /// callers need no separate `history(userID:)` read.
    @discardableResult
    func record(_ result: SearchResult, userID: String) -> [SearchResult] {
        var entries = history(userID: userID)
        entries.removeAll { $0.id == result.id }
        entries.insert(result, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save(entries, userID: userID)
        return entries
    }

    /// Removes one entry, as `SearchView`'s per-row swipe does. Returns the
    /// resulting list, as `record` does.
    @discardableResult
    func remove(id: String, userID: String) -> [SearchResult] {
        var entries = history(userID: userID)
        entries.removeAll { $0.id == id }
        save(entries, userID: userID)
        return entries
    }

    func clear(userID: String) {
        defaults.removeObject(forKey: key(userID: userID))
    }

    private func save(_ entries: [SearchResult], userID: String) {
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: key(userID: userID))
    }
}
