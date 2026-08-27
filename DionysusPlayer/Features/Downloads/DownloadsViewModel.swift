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
    /// On-disk size in bytes for each row, keyed by `DownloadsRow.id` —
    /// precomputed alongside `rows` in `refresh()` rather than read live
    /// from `DownloadsRowView`'s body: each figure is a real filesystem
    /// `stat` call (`DownloadFileStore.fileSize(forRelativePath:)`), and
    /// selection mode re-renders the whole list on every single row tap, so
    /// doing this per-row-per-render would repeat those stats far more than
    /// necessary. A `.show` row sums every one of its **completed**
    /// episodes' video files — an in-progress episode's file size isn't
    /// stable yet, so it's excluded rather than counted mid-write. Missing/
    /// unreadable files count as `0` so one bad file doesn't blank out an
    /// otherwise-real total. Video files only, matching the one existing
    /// per-item size readout (`DownloadedAssetDetailView`'s file-size row) —
    /// subtitle sidecars and artwork aren't included there either.
    private(set) var rowSizes: [String: Int64] = [:]
    private let downloadManager: DownloadManager
    /// How `delete(itemID:)`/`deleteSelected()` schedule the *real*
    /// `DownloadManager.delete(itemID:)` call, after `rows` has already
    /// been updated synchronously — see `delete(itemID:)`'s doc comment for
    /// why this needs to happen on a later run-loop turn, not inline.
    /// Defaults to the real `DispatchQueue.main.async`; test-only DI seam
    /// (matching `DownloadManager`'s own `...Override` seams) lets
    /// `DownloadsViewModelTests` run it synchronously instead of needing to
    /// pump the run loop to observe the deferred deletion.
    private let deferredDeleteScheduler: (@escaping () -> Void) -> Void

    init(
        downloadManager: DownloadManager,
        deferredDeleteScheduler: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.downloadManager = downloadManager
        self.deferredDeleteScheduler = deferredDeleteScheduler
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
        rowSizes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, sizeOnDisk(for: $0, allItems: items)) })
    }

    private func sizeOnDisk(for row: DownloadsRow, allItems: [DownloadedItem]) -> Int64 {
        switch row {
        case .standalone(let item):
            guard item.status == .completed else { return 0 }
            return DownloadFileStore.fileSize(forRelativePath: item.videoFilePath) ?? 0
        case .show(let seriesID, _, _, _):
            var total: Int64 = 0
            for episode in allItems where episode.seriesID == seriesID && episode.status == .completed {
                total += DownloadFileStore.fileSize(forRelativePath: episode.videoFilePath) ?? 0
            }
            return total
        }
    }

    /// Removes the row from `rows` first, synchronously, and only *then*
    /// schedules the real `DownloadManager.delete(itemID:)` (which deletes
    /// the underlying SwiftData object) for the next run-loop turn — not
    /// inline. Confirmed live (2026-08-27): deleting two downloads back to
    /// back crashed inside SwiftData's own generated `DownloadedItem`
    /// property accessors — a still-in-flight `List` row-removal transition
    /// for the *first* delete read a property on a `DownloadedItem` whose
    /// backing row a *second*, immediately-following delete had already
    /// removed from the model context. SwiftData traps on any property
    /// access to a model instance once its store row is gone; there's no
    /// supported way to check "is this instance still valid" before
    /// touching it. Removing from `rows` up front lets SwiftUI's own
    /// diffing/animation finish against a plain value-type array with
    /// nothing left pointing at the row's live model object, so the actual
    /// deletion — deferred past that — can never race a transition that's
    /// still reading it.
    func delete(itemID: String) {
        rows.removeAll { row in
            if case .standalone(let item) = row { return item.itemID == itemID }
            return false
        }
        rowSizes.removeValue(forKey: itemID)
        deferredDeleteScheduler { [downloadManager] in
            downloadManager.delete(itemID: itemID)
        }
    }

    // MARK: Retry

    /// Item IDs with a retry currently in flight — a `Set`, not a single
    /// value, since nothing stops a user retrying more than one failed row
    /// before the first finishes. `DownloadsRowView` reads membership to
    /// show a spinner and disable its own retry button per-row.
    private(set) var retryingItemIDs: Set<String> = []
    var retryErrorMessage: String?

    /// Re-attempts a `.failed` download with its original resolution/
    /// quality/audio choice — see `DownloadManager.retry(itemID:client:)`'s
    /// own doc comment. Always `refresh()`es afterward regardless of
    /// outcome: `rows` holds `DownloadedItem` references directly, and a
    /// successful retry deletes-and-recreates the row under the hood
    /// (`DownloadManager.enqueue`'s own "clean slate" behavior), so the
    /// reference this view model is holding is stale either way.
    func retry(itemID: String, client: JellyfinAPIClient) async {
        guard !retryingItemIDs.contains(itemID) else { return }
        retryingItemIDs.insert(itemID)
        defer {
            retryingItemIDs.remove(itemID)
            refresh()
        }
        do {
            try await downloadManager.retry(itemID: itemID, client: client)
        } catch {
            retryErrorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't retry this download.")
        }
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

    /// Sum of `rowSizes` across the current selection — the Delete
    /// confirmation's own total, and the same figure `deleteSelected()`
    /// below is about to reclaim from disk. A row not yet present in
    /// `rowSizes` (shouldn't happen — both are rebuilt together in
    /// `refresh()`) contributes `0` rather than crashing.
    var selectedTotalBytes: Int64 {
        var total: Int64 = 0
        for rowID in selectedRowIDs {
            total += rowSizes[rowID] ?? 0
        }
        return total
    }

    /// `selectedTotalBytes`, formatted — `nil` rather than "0 B" when the
    /// selection has nothing with a real size yet (e.g. only in-progress
    /// downloads selected, which `rowSizes` deliberately excludes), so the
    /// confirmation dialog falls back to its plain count-only title instead
    /// of claiming an implausible zero-byte deletion.
    var selectedTotalSizeText: String? {
        let total = selectedTotalBytes
        guard total > 0 else { return nil }
        return FileSizeText.text(bytes: total)
    }

    /// Deletes every asset the current selection covers — every episode of
    /// a selected show, not just its group row — then exits selection mode.
    /// `allEpisodes` is fetched once, before the loop, and filtered in
    /// memory per selected show rather than each `.show` row re-fetching
    /// `store.visibleItems()` inside the loop.
    ///
    /// Same "remove from `rows` first, delete the real objects after" order
    /// as `delete(itemID:)` — see its doc comment for the crash this
    /// avoids, which a multi-item bulk delete hits even more easily (more
    /// simultaneous row-removal transitions to race).
    func deleteSelected() {
        let allEpisodes = downloadManager.store.visibleItems()
        var itemIDsToDelete: [String] = []
        for row in rows where selectedRowIDs.contains(row.id) {
            switch row {
            case .standalone(let item):
                itemIDsToDelete.append(item.itemID)
            case .show(let seriesID, _, _, _):
                itemIDsToDelete.append(contentsOf: allEpisodes.filter { $0.seriesID == seriesID }.map(\.itemID))
            }
        }
        rows.removeAll { selectedRowIDs.contains($0.id) }
        for itemID in itemIDsToDelete { rowSizes.removeValue(forKey: itemID) }
        selectedRowIDs = []
        isSelecting = false
        for itemID in itemIDsToDelete {
            deferredDeleteScheduler { [downloadManager] in
                downloadManager.delete(itemID: itemID)
            }
        }
    }
}
