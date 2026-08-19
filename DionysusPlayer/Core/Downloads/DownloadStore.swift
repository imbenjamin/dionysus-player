import Foundation
import SwiftData

/// Thin wrapper around a SwiftData `ModelContainer`/`ModelContext` for
/// offline downloads — `init(modelContainer:)`-injectable for tests
/// (an in-memory container), same DI spirit as `ServerSessionStore`.
@MainActor
final class DownloadStore {
    let modelContainer: ModelContainer
    private var context: ModelContext { modelContainer.mainContext }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// The real on-disk store used by the app. Falls back to an in-memory
    /// container (downloads simply won't survive a relaunch) rather than
    /// throwing/crashing if the on-disk store can't be opened — a corrupt
    /// local cache shouldn't be able to take down the whole app.
    static func makeDefault() -> DownloadStore {
        let schema = Schema([DownloadedItem.self])
        if let onDisk = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)]) {
            return DownloadStore(modelContainer: onDisk)
        }
        // swiftlint:disable:next force_try — an in-memory container has
        // nothing external to fail on; if this throws, something is
        // fundamentally wrong with the schema itself, not the disk.
        let inMemory = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return DownloadStore(modelContainer: inMemory)
    }

    func insert(_ item: DownloadedItem) {
        context.insert(item)
        save()
    }

    func delete(_ item: DownloadedItem) {
        context.delete(item)
        save()
    }

    func save() {
        try? context.save()
    }

    func item(itemID: String) -> DownloadedItem? {
        var descriptor = FetchDescriptor<DownloadedItem>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Every row, including ones kept alive purely to carry a not-yet-
    /// pushed sync payload (`markedForDeletion == true`) — used internally
    /// by `isImagePathReferenced(_:excludingItemID:)`, and by
    /// `DownloadSyncManager`, which needs to see those rows too. UI code
    /// wants `visibleItems()` instead.
    func allItems() -> [DownloadedItem] {
        (try? context.fetch(FetchDescriptor<DownloadedItem>())) ?? []
    }

    /// Downloads the UI should actually list — excludes
    /// `markedForDeletion` rows (deleted in every way a user can observe;
    /// they only still exist to carry a pending sync write). See the
    /// offline-downloads plan's "Delete semantics" section.
    func visibleItems() -> [DownloadedItem] {
        allItems().filter { !$0.markedForDeletion }
    }

    /// Rows with a not-yet-pushed watched/resume write — `DownloadSyncManager`'s
    /// worklist. Includes `markedForDeletion` rows: their whole remaining
    /// purpose is this sync.
    func pendingSyncItems() -> [DownloadedItem] {
        allItems().filter { $0.pendingSync }
    }

    /// True if any *other* downloaded item still references this exact
    /// relative image path — the shared-artwork dedup's "is anyone still
    /// using this" check (see the offline-downloads plan's "Shared artwork
    /// dedup" and "Delete semantics" sections). Checks every row regardless
    /// of status — a `markedForDeletion` row's own stored image path field
    /// still "counts" until that row itself is actually removed.
    func isImagePathReferenced(_ relativePath: String, excludingItemID: String) -> Bool {
        allItems().contains { item in
            guard item.itemID != excludingItemID else { return false }
            return [item.posterImagePath, item.backdropImagePath, item.logoImagePath, item.thumbImagePath]
                .contains(relativePath)
        }
    }
}
