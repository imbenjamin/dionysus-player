import Foundation
import Observation

/// One row in `DownloadsView`'s landing list: either a standalone item (a movie,
/// or a lone episode whose series has no others, collapsed to a leaf row rather
/// than a one-item submenu) or a group of a show's downloaded episodes.
enum DownloadsRow: Identifiable {
    case standalone(StandaloneItem)
    case show(ShowGroup)

    /// Everything the two `DownloadsView` presentations render for a standalone
    /// row, snapshotted as plain values rather than read live off the
    /// `DownloadedItem` it was built from.
    ///
    /// That indirection is load-bearing: SwiftData traps on any property access
    /// to a model whose backing row is gone, with no supported way to ask
    /// whether an instance is still valid. `delete(itemID:)`/`deleteSelected()`
    /// already defer the real deletion past the removal transition, but that
    /// only buys one run-loop turn — holding the live model here let SwiftUI
    /// re-evaluate a removed row's body afterwards and read straight through.
    /// Bulk deletion crashed in `DownloadedItem.metadata.getter` from
    /// `DownloadsView.gridSubtitle(_:)`, since the `.regular` grid re-reads a
    /// row's model during the removal transition where the `.compact` `List`
    /// happened not to. A snapshot closes that for every reader rather than for
    /// the one accessor that trapped first.
    ///
    /// Cheap to build: every field is already in memory, and this is assembled
    /// once per `refresh()`, like `rowSizes` below.
    struct StandaloneItem {
        let itemID: String
        let title: String
        /// `kind == .episode` as a plain flag; `gridTitle` and
        /// `placeholderSystemImage` ask nothing else of the kind.
        let isEpisode: Bool
        let seriesTitle: String?
        let episodeLabel: String?
        let status: DownloadStatus
        let errorMessage: String?
        let yearAndDurationText: String?
        let yearAndDurationAccessibilityText: String?
        let isLandscapeShaped: Bool
        let posterImagePath: String?
        let thumbImagePath: String?
        /// Read only by `sizeOnDisk(for:allItems:)`, while the model is still
        /// alive, so that computation needs no second pass over live items.
        let videoFilePath: String

        init(_ item: DownloadedItem) {
            itemID = item.itemID
            title = item.title
            isEpisode = item.kind == .episode
            seriesTitle = item.seriesTitle
            episodeLabel = item.episodeLabel
            status = item.status
            errorMessage = item.errorMessage
            yearAndDurationText = item.yearAndDurationText
            yearAndDurationAccessibilityText = item.yearAndDurationAccessibilityText
            isLandscapeShaped = item.isLandscapeShaped
            posterImagePath = item.posterImagePath
            thumbImagePath = item.thumbImagePath
            videoFilePath = item.videoFilePath
        }
    }

    /// A show's downloaded episodes collapsed to one row. A struct rather than a
    /// growing tuple of associated values, so adding a display field doesn't
    /// churn every `case .show(_, _, _, _)` pattern across two files.
    struct ShowGroup {
        let seriesID: String
        let seriesTitle: String
        /// From the first episode that has one; an episode's `Primary` image is
        /// its own still frame, not a series poster.
        let posterImagePath: String?
        /// From the first episode that has one: the series `Thumb`, a 16:9
        /// image, and so the better artwork for a landscape grid — which a show
        /// group's vote guarantees (see `isLandscapeShaped`).
        let thumbImagePath: String?
        let episodeCount: Int
    }

    var id: String {
        switch self {
        case .standalone(let item): return "standalone-\(item.itemID)"
        case .show(let group): return "show-\(group.seriesID)"
        }
    }

    var sortTitle: String {
        switch self {
        case .standalone(let item): return item.title
        case .show(let group): return group.seriesTitle
        }
    }

    /// Mirrors `SearchResult.isLandscapeShaped`'s `kind == .episode || kind ==
    /// .series` rule: a show group is the series half and always landscape, a
    /// standalone item defers to its kind.
    var isLandscapeShaped: Bool {
        switch self {
        case .standalone(let item): return item.isLandscapeShaped
        case .show: return true
        }
    }

    /// Whichever artwork fits the shape the grid chose, reusing
    /// `DownloadedItem.artworkRelativePath(preferLandscape:)`'s preference for
    /// the standalone case and mirroring it for a show group.
    func artworkRelativePath(preferLandscape: Bool) -> String? {
        switch self {
        case .standalone(let item):
            return preferLandscape
                ? (item.thumbImagePath ?? item.posterImagePath)
                : (item.posterImagePath ?? item.thumbImagePath)
        case .show(let group):
            return preferLandscape
                ? (group.thumbImagePath ?? group.posterImagePath)
                : (group.posterImagePath ?? group.thumbImagePath)
        }
    }

    /// Content-type glyph for `MediaPlaceholderBox`, matching the `.compact`
    /// list row's.
    var placeholderSystemImage: String {
        switch self {
        case .standalone(let item): return item.isEpisode ? "play.tv" : "film"
        case .show: return "tv"
        }
    }
}

/// Backs `DownloadsView`'s landing screen. Not `@Query`-driven:
/// `DownloadManager` owns its `ModelContainer` privately rather than injecting
/// it into the environment, so this re-reads `DownloadStore` explicitly via
/// `refresh()` on appear and after every mutation — the same ViewModel +
/// explicit reload shape as every other feature, without a network round trip.
@MainActor
@Observable
final class DownloadsViewModel {
    private(set) var rows: [DownloadsRow] = []
    /// On-disk size per row, keyed by `DownloadsRow.id`. Precomputed alongside
    /// `rows` in `refresh()` rather than read from `DownloadsRowView`'s body:
    /// each figure is a filesystem `stat`, and selection mode re-renders the
    /// whole list on every row tap.
    ///
    /// A `.show` row sums its completed episodes' video files only; an
    /// in-progress episode's size isn't stable mid-write. Missing or unreadable
    /// files count as `0`, so one bad file doesn't blank an otherwise-real
    /// total. Video files only, matching
    /// `DownloadedAssetDetailView`'s file-size row — no subtitle sidecars or
    /// artwork there either.
    private(set) var rowSizes: [String: Int64] = [:]
    private let downloadManager: DownloadManager
    /// How `delete(itemID:)`/`deleteSelected()` schedule the real
    /// `DownloadManager.delete(itemID:)` after `rows` is updated synchronously
    /// — see `delete(itemID:)` for why it can't be inline. Defaults to a
    /// `Task { @MainActor in ... }` hop; a test-only DI seam, like
    /// `DownloadManager`'s `...Override` seams, lets `DownloadsViewModelTests`
    /// run it synchronously rather than pumping the run loop.
    ///
    /// `@MainActor` rather than `@Sendable` on the closure: the requirement is
    /// to run on the main actor, which both call sites already are, and
    /// `DispatchQueue.main.async`'s `@Sendable` never fit a non-Sendable capture
    /// meant for one actor.
    private let deferredDeleteScheduler: (@escaping @MainActor () -> Void) -> Void

    init(
        downloadManager: DownloadManager,
        deferredDeleteScheduler: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        }
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

        var result: [DownloadsRow] = standalone.map { .standalone(DownloadsRow.StandaloneItem($0)) }
        for (seriesID, episodes) in byShow {
            if episodes.count > 1, let first = episodes.first {
                result.append(.show(DownloadsRow.ShowGroup(
                    seriesID: seriesID,
                    seriesTitle: first.seriesTitle ?? first.title,
                    posterImagePath: episodes.first { $0.posterImagePath != nil }?.posterImagePath,
                    thumbImagePath: episodes.first { $0.thumbImagePath != nil }?.thumbImagePath,
                    episodeCount: episodes.count
                )))
            } else if let only = episodes.first {
                result.append(.standalone(DownloadsRow.StandaloneItem(only)))
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
        case .show(let group):
            let seriesID = group.seriesID
            var total: Int64 = 0
            for episode in allItems where episode.seriesID == seriesID && episode.status == .completed {
                total += DownloadFileStore.fileSize(forRelativePath: episode.videoFilePath) ?? 0
            }
            return total
        }
    }

    /// Removes the row from `rows` synchronously, then schedules the real
    /// `DownloadManager.delete(itemID:)` for the next run-loop turn rather than
    /// running it inline. Deleting two downloads back to back crashed inside
    /// SwiftData's generated `DownloadedItem` accessors: the first delete's
    /// in-flight row-removal transition read a property on a model whose backing
    /// row the second delete had already removed. SwiftData traps on any such
    /// access, with no way to test validity first. Removing from `rows` up front
    /// leaves SwiftUI diffing a plain value-type array with nothing pointing at
    /// the live model.
    ///
    /// The deferral is necessary but not sufficient: it buys one run-loop turn,
    /// and `rows` used to hold the live `DownloadedItem`, so a later re-render
    /// could still read through to a deleted row. See
    /// `DownloadsRow.StandaloneItem`, which closes that.
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

    /// Item IDs with a retry in flight. A `Set`, since nothing stops the user
    /// retrying several failed rows at once; `DownloadsRowView` reads membership
    /// to show a spinner and disable that row's retry button.
    private(set) var retryingItemIDs: Set<String> = []
    var retryErrorMessage: String?

    /// Re-attempts a `.failed` download with its original
    /// resolution/quality/audio choice (see
    /// `DownloadManager.retry(itemID:client:)`). Always `refresh()`es
    /// afterwards: a successful retry deletes and recreates the underlying row,
    /// so the `DownloadsRow.StandaloneItem` snapshot held here describes a row
    /// that no longer exists.
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
    /// Keyed by `DownloadsRow.id`, not an item id: a selected `.show` row stands
    /// for every episode in it, so selection tracks what the user taps and
    /// `selectedAssetCount`/`deleteSelected()` expand it where it matters.
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

    /// Downloaded assets the selection covers: a `.standalone` row counts 1, a
    /// `.show` row its `episodeCount`, since deleting it deletes every episode.
    /// `selectedRowIDs.count` would undercount any selected show.
    var selectedAssetCount: Int {
        rows.filter { selectedRowIDs.contains($0.id) }
            .reduce(0) { total, row in
                switch row {
                case .standalone: return total + 1
                case .show(let group): return total + group.episodeCount
                }
            }
    }

    /// Sum of `rowSizes` across the selection: the Delete confirmation's total,
    /// and what `deleteSelected()` reclaims. A row missing from `rowSizes`
    /// contributes `0` rather than crashing, though both are rebuilt together in
    /// `refresh()`.
    var selectedTotalBytes: Int64 {
        var total: Int64 = 0
        for rowID in selectedRowIDs {
            total += rowSizes[rowID] ?? 0
        }
        return total
    }

    /// `selectedTotalBytes`, formatted. `nil` rather than "0 B" when nothing in
    /// the selection has a size yet — only in-progress downloads, which
    /// `rowSizes` excludes — so the confirmation falls back to its count-only
    /// title rather than claiming a zero-byte deletion.
    var selectedTotalSizeText: String? {
        let total = selectedTotalBytes
        guard total > 0 else { return nil }
        return FileSizeText.text(bytes: total)
    }

    /// Deletes every asset the selection covers, including each episode of a
    /// selected show, then exits selection mode. `allEpisodes` is fetched once
    /// before the loop and filtered in memory, rather than each `.show` row
    /// re-fetching `store.visibleItems()`.
    ///
    /// Same "remove from `rows` first, delete after" order as
    /// `delete(itemID:)`, whose crash a bulk delete hits even more easily.
    func deleteSelected() {
        let allEpisodes = downloadManager.store.visibleItems()
        var itemIDsToDelete: [String] = []
        for row in rows where selectedRowIDs.contains(row.id) {
            switch row {
            case .standalone(let item):
                itemIDsToDelete.append(item.itemID)
            case .show(let group):
                itemIDsToDelete.append(contentsOf: allEpisodes.filter { $0.seriesID == group.seriesID }.map(\.itemID))
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
