import Foundation

/// Persists the user's recent "successful" searches — a search result they
/// actually selected, not just what they typed — so `SearchView`'s landing
/// page can offer one-tap access back to previously found content.
///
/// Local to the device only: plain `UserDefaults`, like `ServerSessionStore`'s
/// server config (not sensitive, and — deliberately — never round-tripped
/// through the Jellyfin server). Scoped per user (keyed by `userID`) so a
/// shared device switching accounts doesn't leak one user's history to
/// another.
final class SearchHistoryStore {
    /// Recent-searches lists are meant to be a handful of quick shortcuts
    /// back to something you just looked at, not a full log — trimmed to
    /// this many entries, most recent first.
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

    /// Records `result` as the most recent entry. If it's already present
    /// (the user re-selected something already in their history), it moves
    /// to the front instead of duplicating.
    func record(_ result: SearchResult, userID: String) {
        var entries = history(userID: userID)
        entries.removeAll { $0.id == result.id }
        entries.insert(result, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save(entries, userID: userID)
    }

    /// Removes a single entry (e.g. via `SearchView`'s per-row swipe
    /// action), as opposed to `clear`'s wipe-everything.
    func remove(id: String, userID: String) {
        var entries = history(userID: userID)
        entries.removeAll { $0.id == id }
        save(entries, userID: userID)
    }

    func clear(userID: String) {
        defaults.removeObject(forKey: key(userID: userID))
    }

    private func save(_ entries: [SearchResult], userID: String) {
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: key(userID: userID))
    }
}
