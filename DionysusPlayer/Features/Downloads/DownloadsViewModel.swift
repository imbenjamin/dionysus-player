import Foundation
import Observation

/// One row in `DownloadsView`'s landing list — either a standalone item (a
/// downloaded movie, or a lone episode whose series has no other
/// downloaded episodes — collapsed straight to a leaf row rather than a
/// one-item "submenu") or a group of a show's downloaded episodes.
enum DownloadsRow: Identifiable {
    case standalone(DownloadedItem)
    case show(seriesID: String, seriesTitle: String, posterImagePath: String?, episodeCount: Int)

    var id: String {
        switch self {
        case .standalone(let item): return "standalone-\(item.itemID)"
        case .show(let seriesID, _, _, _): return "show-\(seriesID)"
        }
    }

    var sortTitle: String {
        switch self {
        case .standalone(let item): return item.title
        case .show(_, let seriesTitle, _, _): return seriesTitle
        }
    }
}

/// Backs `DownloadsView`'s landing screen. Deliberately not `@Query`-driven
/// (SwiftData's auto-updating SwiftUI property wrapper): `DownloadManager`
/// owns its `ModelContainer` privately rather than injecting it into the
/// environment via `.modelContainer(_:)` (which nothing else in this app
/// does either), so this instead re-reads `DownloadStore` explicitly via
/// `refresh()` — called on appear and after every mutation
/// (`delete(itemID:)`) — same "ViewModel + explicit reload" shape as every
/// other feature in this app, just without a network round trip to wait on.
@MainActor
@Observable
final class DownloadsViewModel {
    private(set) var rows: [DownloadsRow] = []
    private let downloadManager: DownloadManager

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
        refresh()
    }

    func refresh() {
        let items = downloadManager.store.visibleItems()
        var byShow: [String: [DownloadedItem]] = [:]
        var standalone: [DownloadedItem] = []
        for item in items {
            if let seriesID = item.seriesID {
                byShow[seriesID, default: []].append(item)
            } else {
                standalone.append(item)
            }
        }

        var result: [DownloadsRow] = standalone.map(DownloadsRow.standalone)
        for (seriesID, episodes) in byShow {
            if episodes.count > 1, let first = episodes.first {
                result.append(.show(
                    seriesID: seriesID,
                    seriesTitle: first.seriesTitle ?? first.title,
                    posterImagePath: episodes.first { $0.posterImagePath != nil }?.posterImagePath,
                    episodeCount: episodes.count
                ))
            } else if let only = episodes.first {
                result.append(.standalone(only))
            }
        }
        rows = result.sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
    }

    func delete(itemID: String) {
        downloadManager.delete(itemID: itemID)
        refresh()
    }

    // MARK: Bulk selection

    var isSelecting = false
    /// Keyed by `DownloadsRow.id`, not an item id — a selected `.show` row
    /// represents every episode within it, not one asset, so selection has
    /// to track rows (what the user actually sees and taps), with
    /// `selectedAssetCount`/`deleteSelected()` expanding a show row out to
    /// its real episodes only where it matters.
    private(set) var selectedRowIDs: Set<String> = []

    func beginSelecting() {
        isSelecting = true
        selectedRowIDs = []
    }

    func cancelSelecting() {
        isSelecting = false
        selectedRowIDs = []
    }

    func toggleSelection(_ rowID: String) {
        if selectedRowIDs.contains(rowID) {
            selectedRowIDs.remove(rowID)
        } else {
            selectedRowIDs.insert(rowID)
        }
    }

    var isAllSelected: Bool {
        !rows.isEmpty && selectedRowIDs.count == rows.count
    }

    func toggleSelectAll() {
        selectedRowIDs = isAllSelected ? [] : Set(rows.map(\.id))
    }

    /// Total individual downloaded assets the current selection actually
    /// covers — a `.standalone` row counts as 1, a `.show` row counts as
    /// its own `episodeCount` (deleting a show row deletes every episode
    /// within it), so this is the real number to confirm against, not
    /// just `selectedRowIDs.count` (which would undercount any selected
    /// show).
    var selectedAssetCount: Int {
        rows.filter { selectedRowIDs.contains($0.id) }
            .reduce(0) { total, row in
                switch row {
                case .standalone: return total + 1
                case .show(_, _, _, let episodeCount): return total + episodeCount
                }
            }
    }

    /// Deletes every asset the current selection covers — every episode of
    /// a selected show, not just its group row — then exits selection mode.
    /// `allEpisodes` is fetched once, before the loop, and filtered in
    /// memory per selected show rather than each `.show` row re-fetching
    /// `store.visibleItems()` inside the loop.
    func deleteSelected() {
        let allEpisodes = downloadManager.store.visibleItems()
        for row in rows where selectedRowIDs.contains(row.id) {
            switch row {
            case .standalone(let item):
                downloadManager.delete(itemID: item.itemID)
            case .show(let seriesID, _, _, _):
                for episode in allEpisodes where episode.seriesID == seriesID {
                    downloadManager.delete(itemID: episode.itemID)
                }
            }
        }
        selectedRowIDs = []
        isSelecting = false
        refresh()
    }
}
