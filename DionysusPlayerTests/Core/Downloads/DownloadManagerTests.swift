import XCTest
@testable import Dionysus

/// `DownloadManager.delete(itemID:)`'s own logic — the real download engine
/// (background `URLSessionDownloadTask`/`AppDelegate` relaunch wiring) is
/// explicitly not unit-tested here, per the offline-downloads plan's
/// Testing section — Simulator background-session behavior diverges from
/// device and `MockURLProtocol` doesn't intercept delegate-based download
/// tasks. This exercises delete's own file-cleanup/row-survival rules
/// directly against a real `DownloadFileStore` (cleaned up in `tearDown`)
/// and an in-memory `DownloadStore`.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private var touchedRelativePaths: [String] = []

    override func tearDown() {
        for path in touchedRelativePaths { try? FileManager.default.removeItem(at: DownloadFileStore.url(forRelativePath: path)) }
        touchedRelativePaths = []
        super.tearDown()
    }

    private func writeFile(itemID: String) throws {
        touchedRelativePaths.append(DownloadFileStore.videoRelativePath(itemID: itemID))
        try DownloadFileStore.write(Data("video".utf8), toRelativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
    }

    // MARK: pendingSync survives file deletion

    func test_delete_withoutPendingSync_removesRowAndFiles() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: false))

        manager.delete(itemID: "item-1")

        XCTAssertNil(store.item(itemID: "item-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: "item-1")).path))
    }

    /// The core new behavior this session added: deleting a download with
    /// unsynced watched/resume state frees the files but keeps the row
    /// alive (marked for deletion) purely to carry that pending sync write.
    func test_delete_withPendingSync_freesFilesButKeepsRowMarkedForDeletion() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))

        manager.delete(itemID: "item-1")

        let row = store.item(itemID: "item-1")
        XCTAssertNotNil(row, "row must survive to carry the pending sync write")
        XCTAssertEqual(row?.markedForDeletion, true)
        XCTAssertEqual(row?.pendingSync, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: "item-1")).path))
    }

    /// A `markedForDeletion` row must not reappear in the UI-facing list.
    func test_delete_withPendingSync_rowIsExcludedFromVisibleItems() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))

        manager.delete(itemID: "item-1")

        XCTAssertTrue(store.visibleItems().isEmpty)
        XCTAssertEqual(store.pendingSyncItems().map(\.itemID), ["item-1"])
    }

    // MARK: shared-image dedup on delete

    func test_delete_sharedImage_stillReferencedByAnotherItem_fileSurvives() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let tag = "shared-\(UUID().uuidString)"
        let logoPath = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: tag)
        touchedRelativePaths.append(logoPath)
        try DownloadFileStore.write(Data("logo".utf8), toRelativePath: logoPath)
        try writeFile(itemID: "ep-1")
        try writeFile(itemID: "ep-2")
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: logoPath))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-2", logoImagePath: logoPath))

        manager.delete(itemID: "ep-1")

        XCTAssertNil(store.item(itemID: "ep-1"))
        XCTAssertNotNil(store.item(itemID: "ep-2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: logoPath).path), "shared logo must survive while ep-2 still references it")
    }

    func test_delete_sharedImage_lastReference_fileIsFreed() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let tag = "unshared-\(UUID().uuidString)"
        let logoPath = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: tag)
        touchedRelativePaths.append(logoPath)
        try DownloadFileStore.write(Data("logo".utf8), toRelativePath: logoPath)
        try writeFile(itemID: "ep-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: logoPath))

        manager.delete(itemID: "ep-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: logoPath).path))
    }

    func test_delete_unknownItemID_isNoOp() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        manager.delete(itemID: "does-not-exist") // must not crash
    }

    // MARK: concurrency-limited queue

    private let concurrencyTestsSuiteName = "com.dionysusplayer.tests.DownloadManagerTests.concurrency"

    /// An isolated `DownloadPreferencesStore` (its own `UserDefaults`
    /// suite, not `.standard`) with `maxConcurrentDownloads` pre-set to
    /// `limit` — injected into `DownloadManager` below rather than mutating
    /// real app defaults for the duration of a test.
    private func makePreferences(maxConcurrentDownloads limit: Int) -> DownloadPreferencesStore {
        let defaults = UserDefaults(suiteName: concurrencyTestsSuiteName)!
        defaults.removePersistentDomain(forName: concurrencyTestsSuiteName)
        defaults.set(limit, forKey: downloadMaxConcurrentStorageKey)
        return DownloadPreferencesStore(defaults: defaults)
    }

    /// A manager whose `startVideoDownloadOverride` just records which item
    /// was told to start, instead of touching the network —
    /// `admitQueuedDownloadsIfPossible` itself reserves the concurrency
    /// slot before calling this (see its own doc comment), so the override
    /// doesn't need to call back into the manager at all.
    private func makeManagerWithFakeStarter(
        store: DownloadStore, maxConcurrentDownloads limit: Int, started: @escaping (String) -> Void = { _ in }
    ) -> DownloadManager {
        DownloadManager(store: store, preferences: makePreferences(maxConcurrentDownloads: limit)) { itemID, _, _ in started(itemID) }
    }

    func test_queueVideoDownload_underLimit_admitsImmediately() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = makeManagerWithFakeStarter(store: store, maxConcurrentDownloads: 5)
        let row = DownloadTestHelpers.makeItem(itemID: "item-1", status: .queued, pendingDownloadURLString: "https://example.com/1")
        store.insert(row)

        manager.queueVideoDownload(itemID: "item-1")

        XCTAssertEqual(store.item(itemID: "item-1")?.status, .downloading)
        XCTAssertNil(store.item(itemID: "item-1")?.pendingDownloadURLString, "consumed once admitted")
    }

    /// The core new behavior: once the limit is reached, further items stay
    /// `.queued` instead of starting, and admit strictly in the order they
    /// were queued once a slot frees up.
    func test_queueVideoDownload_overLimit_waitsThenAdmitsInFIFOOrderOnceASlotFrees() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        var startedOrder: [String] = []
        let manager = makeManagerWithFakeStarter(store: store, maxConcurrentDownloads: 1) { startedOrder.append($0) }
        for itemID in ["item-1", "item-2", "item-3"] {
            store.insert(DownloadTestHelpers.makeItem(itemID: itemID, status: .queued, pendingDownloadURLString: "https://example.com/\(itemID)"))
        }

        manager.queueVideoDownload(itemID: "item-1")
        manager.queueVideoDownload(itemID: "item-2")
        manager.queueVideoDownload(itemID: "item-3")

        XCTAssertEqual(store.item(itemID: "item-1")?.status, .downloading)
        XCTAssertEqual(store.item(itemID: "item-2")?.status, .queued)
        XCTAssertEqual(store.item(itemID: "item-3")?.status, .queued)

        manager.test_simulateDownloadFinished(itemID: "item-1")
        XCTAssertEqual(store.item(itemID: "item-2")?.status, .downloading)
        XCTAssertEqual(store.item(itemID: "item-3")?.status, .queued)

        manager.test_simulateDownloadFinished(itemID: "item-2")
        XCTAssertEqual(store.item(itemID: "item-3")?.status, .downloading)

        XCTAssertEqual(startedOrder, ["item-1", "item-2", "item-3"], "must admit in the order queued")
    }

    func test_queueVideoDownload_unlimited_admitsEveryItemAtOnce() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = makeManagerWithFakeStarter(store: store, maxConcurrentDownloads: 0)
        for itemID in ["item-1", "item-2", "item-3"] {
            store.insert(DownloadTestHelpers.makeItem(itemID: itemID, status: .queued, pendingDownloadURLString: "https://example.com/\(itemID)"))
            manager.queueVideoDownload(itemID: itemID)
        }

        for itemID in ["item-1", "item-2", "item-3"] {
            XCTAssertEqual(store.item(itemID: itemID)?.status, .downloading)
        }
    }

    /// A `.queued` row left over from a previous launch (never got as far
    /// as starting a real background session) must be picked back up, not
    /// abandoned — see `DownloadManager.resumePendingQueue`.
    func test_init_resumesLeftoverQueuedRowsRespectingTheLimit() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let older = Date().addingTimeInterval(-60)
        let newer = Date()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-old", status: .queued, pendingDownloadURLString: "https://example.com/old", createdAt: older))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-new", status: .queued, pendingDownloadURLString: "https://example.com/new", createdAt: newer))

        // `init` itself (via `resumePendingQueue`) is what's under test
        // here — never referenced again once constructed.
        _ = makeManagerWithFakeStarter(store: store, maxConcurrentDownloads: 1)

        XCTAssertEqual(store.item(itemID: "item-old")?.status, .downloading, "older row must be admitted first")
        XCTAssertEqual(store.item(itemID: "item-new")?.status, .queued)
    }

    /// Deleting a still-`.queued` item before it ever started must drop it
    /// from the pending queue too, or it would otherwise sit there forever
    /// referencing a row that no longer exists.
    func test_delete_queuedItem_removesItFromThePendingQueue() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        var startedOrder: [String] = []
        let manager = makeManagerWithFakeStarter(store: store, maxConcurrentDownloads: 1) { startedOrder.append($0) }
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .queued, pendingDownloadURLString: "https://example.com/1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2", status: .queued, pendingDownloadURLString: "https://example.com/2"))
        manager.queueVideoDownload(itemID: "item-1")
        manager.queueVideoDownload(itemID: "item-2")
        XCTAssertEqual(store.item(itemID: "item-2")?.status, .queued)

        manager.delete(itemID: "item-2")
        manager.test_simulateDownloadFinished(itemID: "item-1")

        XCTAssertNil(store.item(itemID: "item-2"), "deleted, must not have been admitted")
        XCTAssertEqual(startedOrder, ["item-1"])
    }
}
