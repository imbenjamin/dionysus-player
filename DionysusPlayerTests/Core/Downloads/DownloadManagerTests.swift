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
}
