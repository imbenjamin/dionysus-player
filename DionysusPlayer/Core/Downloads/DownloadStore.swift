import Foundation
import Observation
import SwiftData
import os

/// Thin wrapper around a SwiftData container for offline downloads, injectable
/// so tests can pass an in-memory one.
@MainActor
@Observable
final class DownloadStore {
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "DownloadStore")

    let modelContainer: ModelContainer
    private var context: ModelContext { modelContainer.mainContext }

    /// Bumped on every successful `save()`. A view calling
    /// `store.item(itemID:)` isn't Observation-tracked — that is a raw
    /// `context.fetch`, not a read of an `@Observable` property — so it would
    /// stop re-rendering when the row changed elsewhere. Reading this alongside
    /// gives SwiftUI a tracked dependency to invalidate on.
    private(set) var changeCount = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// The app's on-disk store, falling back to an in-memory container — losing
    /// downloads across a relaunch — rather than crashing: a corrupt local cache
    /// shouldn't take down the app.
    static func makeDefault() -> DownloadStore {
        // `Application Support` doesn't exist on a first launch, and SwiftData's
        // preflight `statfs` then logs a "Failed to stat path"/"Sandbox access
        // denied" pair. Harmless — the store is created anyway — but it surfaces
        // as a CI annotation. Pre-creating the directory avoids the miss.
        if let supportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        }
        let schema = Schema([DownloadedItem.self])
        if let onDisk = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)]) {
            return DownloadStore(modelContainer: onDisk)
        }
        // swiftlint:disable:next force_try — an in-memory container has nothing
        // external to fail on, so a throw here means a broken schema.
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

    /// Persists status transitions, `pendingSync` clears and deletes for every
    /// write path. Non-throwing, since call sites treat a save as
    /// fire-and-forget, but logs failures: a multi-GB download is a realistic
    /// way to fill device storage and hit one.
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

    /// Every row matching `itemIDs` in one query, for a caller that knows which
    /// ids it wants — `SeasonDownloadButton`'s season-wide checks — instead of N
    /// predicate fetches from a loop of `item(itemID:)`.
    func items(itemIDs: Set<String>) -> [DownloadedItem] {
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: #Predicate { itemIDs.contains($0.itemID) })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every row, including `markedForDeletion` ones kept alive to carry a
    /// pending sync payload. For `isImagePathReferenced(_:excludingItemID:)` and
    /// `DownloadSyncManager`; UI code wants `visibleItems()`.
    func allItems() -> [DownloadedItem] {
        (try? context.fetch(FetchDescriptor<DownloadedItem>())) ?? []
    }

    /// Downloads the UI lists, excluding `markedForDeletion` rows — deleted in
    /// every way a user can observe, and surviving only to carry a pending sync.
    func visibleItems() -> [DownloadedItem] {
        allItems().filter { !$0.markedForDeletion }
    }

    /// Rows with an unpushed watched or resume write: `DownloadSyncManager`'s
    /// worklist. Includes `markedForDeletion` rows, whose only purpose is this.
    func pendingSyncItems() -> [DownloadedItem] {
        allItems().filter { $0.pendingSync }
    }

    /// Whether any other downloaded item references this image path: the
    /// shared-artwork dedup's liveness check. Counts every row regardless of
    /// status, since a `markedForDeletion` row's stored path still holds the
    /// file until that row is removed.
    func isImagePathReferenced(_ relativePath: String, excludingItemID: String) -> Bool {
        isImagePathReferenced(relativePath, excludingItemID: excludingItemID, among: allItems())
    }

    /// The same check against an already-fetched snapshot, so a caller checking
    /// several paths — `DownloadManager.delete(itemID:)`'s four image fields —
    /// pays one full-table fetch rather than one per field.
    func isImagePathReferenced(_ relativePath: String, excludingItemID: String, among items: [DownloadedItem]) -> Bool {
        items.contains { item in
            guard item.itemID != excludingItemID else { return false }
            // Chapter stills share the content-addressed pool, so a path named
            // by another row's chapter list keeps its file like a series logo.
            if [item.posterImagePath, item.backdropImagePath, item.logoImagePath, item.thumbImagePath].contains(relativePath) {
                return true
            }
            return item.chapters.contains { $0.imageRelativePath == relativePath }
        }
    }
}
