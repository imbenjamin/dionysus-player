import Foundation
import Observation
import SwiftData
import os

/// Thin wrapper around a SwiftData `ModelContainer`/`ModelContext` for
/// offline downloads — `init(modelContainer:)`-injectable for tests
/// (an in-memory container), same DI spirit as `ServerSessionStore`.
@MainActor
@Observable
final class DownloadStore {
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "DownloadStore")

    let modelContainer: ModelContainer
    private var context: ModelContext { modelContainer.mainContext }

    /// Bumped on every successful `save()` — i.e. every mutation this store
    /// makes, from anywhere. A plain SwiftUI view computing
    /// `store.item(itemID:)`/`.allItems()` isn't itself Observation-tracked
    /// (it's a raw SwiftData `context.fetch`, not a read of an
    /// `@Observable` stored property), so a view could silently stop
    /// re-rendering when the underlying row changed from somewhere else
    /// entirely. Every such computed property also reads this, giving
    /// SwiftUI a real, tracked dependency to invalidate on.
    private(set) var changeCount = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// The real on-disk store used by the app. Falls back to an in-memory
    /// container (downloads simply won't survive a relaunch) rather than
    /// throwing/crashing if the on-disk store can't be opened — a corrupt
    /// local cache shouldn't be able to take down the whole app.
    static func makeDefault() -> DownloadStore {
        // On a brand-new app container (a fresh Simulator, or a device's
        // first launch after install) `Application Support` doesn't exist
        // yet — SwiftData's preflight `statfs` on it before creating the
        // store file then logs a "Failed to stat path"/"Sandbox access ...
        // denied" pair (harmless; the store still gets created either way,
        // but it shows up as a scary CI annotation). Pre-creating the
        // directory, same boilerplate Apple's own Core Data templates
        // include, avoids that preflight ever missing.
        if let supportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        }
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

    /// Every write path in `DownloadManager`/`DownloadSyncManager` relies on
    /// this to persist status transitions, `pendingSync` clears, and
    /// deletes. Still non-throwing (every call site treats a save as
    /// fire-and-forget), but logs a failure rather than swallowing it
    /// silently — a multi-GB transcode download is a realistic way to
    /// actually fill device storage and hit a genuine save failure.
    func save() {
        defer { changeCount += 1 }
        do {
            try context.save()
        } catch {
            Self.logger.error("DownloadStore.save() failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func item(itemID: String) -> DownloadedItem? {
        var descriptor = FetchDescriptor<DownloadedItem>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Every row whose `itemID` is one of `itemIDs`, in a single query —
    /// for a caller that already knows exactly which ids it cares about
    /// (e.g. `SeasonDownloadButton`'s season-wide status/progress checks)
    /// instead of calling `item(itemID:)` once per id in a loop, which
    /// used to cost N individual predicate fetches for N episodes.
    func items(itemIDs: Set<String>) -> [DownloadedItem] {
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: #Predicate { itemIDs.contains($0.itemID) })
        return (try? context.fetch(descriptor)) ?? []
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
        isImagePathReferenced(relativePath, excludingItemID: excludingItemID, among: allItems())
    }

    /// Same check as above, against an already-fetched snapshot instead of
    /// querying SwiftData again — for a caller checking several paths in a
    /// row (`DownloadManager.delete(itemID:)`'s four image fields used to
    /// call the single-path overload once per field, each doing its own
    /// full-table `allItems()` fetch; fetching once and reusing the same
    /// snapshot across all four checks avoids that).
    func isImagePathReferenced(_ relativePath: String, excludingItemID: String, among items: [DownloadedItem]) -> Bool {
        items.contains { item in
            guard item.itemID != excludingItemID else { return false }
            // Chapter stills are checked alongside the four single-image
            // fields — they live in the same shared, content-addressed pool,
            // so a path still named by any other row's chapter list must
            // keep its file, exactly as a shared series logo does.
            if [item.posterImagePath, item.backdropImagePath, item.logoImagePath, item.thumbImagePath].contains(relativePath) {
                return true
            }
            return item.chapters.contains { $0.imageRelativePath == relativePath }
        }
    }
}
