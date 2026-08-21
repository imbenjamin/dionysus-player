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
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private func makeClient() -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
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

    // MARK: onRowMarkedForDeletion (2026-08-20) — the "spinner stuck
    // indefinitely" bug: a deleted-but-pending-sync row used to only ever
    // clear on the next scenePhase foreground/reconnect trigger; this
    // fires immediately instead so whoever's listening (`AppState`) can
    // nudge `DownloadSyncManager` right away.

    func test_delete_withPendingSync_firesOnRowMarkedForDeletionCallback() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        var callbackFired = false
        manager.onRowMarkedForDeletion = { callbackFired = true }

        manager.delete(itemID: "item-1")

        XCTAssertTrue(callbackFired)
    }

    /// A row deleted outright (no unsynced state to carry) never becomes
    /// `markedForDeletion` at all — nothing for the callback to fire for.
    func test_delete_withoutPendingSync_doesNotFireOnRowMarkedForDeletionCallback() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: false))
        var callbackFired = false
        manager.onRowMarkedForDeletion = { callbackFired = true }

        manager.delete(itemID: "item-1")

        XCTAssertFalse(callbackFired)
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

    // MARK: retry(itemID:client:) — the one-tap "redownload a failed item"
    // action (2026-08-20), added per direct feedback. Only the branches
    // that don't require `enqueue()`'s own network-heavy internals
    // (image/trickplay/subtitle side-fetches, all via `URLSession.shared`,
    // not this test's mocked client session) to actually run to completion
    // are covered here — same "don't unit-test the real download engine"
    // boundary this file's own doc comment already documents for `enqueue`
    // itself, which nothing here calls directly either.

    func test_retry_rowNotFailed_isNoOpAndMakesNoRequest() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .downloading))
        MockURLProtocol.requestHandler = { _ in XCTFail("must not hit the network for a non-failed row"); throw URLError(.badURL) }

        try await manager.retry(itemID: "item-1", client: makeClient())
    }

    func test_retry_unknownItemID_isNoOp() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        MockURLProtocol.requestHandler = { _ in XCTFail("must not hit the network for a row that doesn't exist"); throw URLError(.badURL) }

        try await manager.retry(itemID: "does-not-exist", client: makeClient())
    }

    /// The item itself is gone from the server (removed from the library
    /// since the original download) — surfaced as a clear, specific error
    /// rather than whatever generic failure the raw fetch produced.
    func test_retry_itemNoLongerOnServer_throwsItemNoLongerAvailable() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .failed))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
        }

        do {
            try await manager.retry(itemID: "item-1", client: makeClient())
            XCTFail("expected itemNoLongerAvailable")
        } catch let error as DownloadError {
            XCTAssertEqual(error.errorDescription, DownloadError.itemNoLongerAvailable.errorDescription)
        }
    }

    /// The item still exists, but this specific negotiation came back with
    /// no playable source at all.
    func test_retry_noMediaSources_throwsMissingMediaSource() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .failed))
        let dto = BaseItemDto(id: "item-1", name: "Test Movie", type: .movie)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/Items/item-1/PlaybackInfo" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: PlaybackInfoResponse(mediaSources: []))
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: dto)
        }

        do {
            try await manager.retry(itemID: "item-1", client: makeClient())
            XCTFail("expected missingMediaSource")
        } catch let error as DownloadError {
            XCTAssertEqual(error.errorDescription, DownloadError.missingMediaSource.errorDescription)
        }
    }

    // MARK: init sweeps orphaned files (the "13 GB with an empty Downloads
    // list" bug, 2026-08-20) — see `DownloadFileStore
    // .deleteOrphanedItemDirectories`'s own doc comment for the full story.

    func test_init_sweepsOrphanedItemDirectoriesWithNoMatchingRow() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        try writeFile(itemID: "orphan-1") // no row for this itemID at all
        try writeFile(itemID: "item-1")
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))

        _ = DownloadManager(store: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: "orphan-1")).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: "item-1")).path))
    }

    // MARK: init reattaches in-flight downloads on a plain relaunch
    // (2026-08-20 branch review) — see `DownloadManager
    // .reattachInFlightDownloads`'s own doc comment for the bug this fixes:
    // a `.downloading` row surviving an ordinary relaunch (not an
    // OS-triggered background-events launch) never got a session recreated
    // for it at all, leaving it stuck forever.

    /// Verified indirectly, the same way `delegates.count` is already used
    /// elsewhere in this manager as "how many video downloads are actually
    /// transferring right now": a `.downloading` row reattached at `init`
    /// must occupy a concurrency slot, so a freshly `.queued` item can't be
    /// admitted past the limit until that slot frees.
    func test_init_reattachesInFlightDownloadingRowsOccupyingAConcurrencySlot() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "already-downloading", status: .downloading))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-new", status: .queued, pendingDownloadURLString: "https://example.com/new"))
        var reattachedItemIDs: [String] = []

        let manager = DownloadManager(
            store: store,
            preferences: makePreferences(maxConcurrentDownloads: 1),
            startVideoDownloadOverride: { _, _, _ in },
            reattachVideoDownloadOverride: { reattachedItemIDs.append($0) }
        )

        XCTAssertEqual(reattachedItemIDs, ["already-downloading"])
        manager.queueVideoDownload(itemID: "item-new")
        XCTAssertEqual(store.item(itemID: "item-new")?.status, .queued, "the reattached row must already occupy the one available slot")
    }

    /// A row still `.completed`/`.failed`/`.queued` must not be reattached —
    /// only a genuinely `.downloading` one has a background session left to
    /// recover.
    func test_init_doesNotReattachNonDownloadingRows() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "completed-item", status: .completed))
        store.insert(DownloadTestHelpers.makeItem(itemID: "failed-item", status: .failed))
        var reattachedItemIDs: [String] = []

        _ = DownloadManager(
            store: store,
            preferences: makePreferences(maxConcurrentDownloads: 1),
            reattachVideoDownloadOverride: { reattachedItemIDs.append($0) }
        )

        XCTAssertTrue(reattachedItemIDs.isEmpty)
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

    // MARK: cancel-on-delete (the "Rushmore" -999 bug, 2026-08-20)

    /// The core regression this session fixed: deleting a row that's
    /// actually `.downloading` (a real background session started) must
    /// cancel that session, not just drop this manager's own bookkeeping —
    /// see `DownloadManager.delete(itemID:)`'s own doc comment for the real
    /// bug (an orphaned background session left an identifier the OS still
    /// considered "in use", so a same-day re-download of the same item got
    /// its brand-new session's task cancelled almost immediately).
    func test_delete_downloadingItem_cancelsItsSession() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        var cancelledItemIDs: [String] = []
        let manager = DownloadManager(
            store: store,
            preferences: makePreferences(maxConcurrentDownloads: 5),
            startVideoDownloadOverride: { _, _, _ in },
            cancelVideoDownloadOverride: { cancelledItemIDs.append($0) }
        )
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .queued, pendingDownloadURLString: "https://example.com/1"))
        manager.queueVideoDownload(itemID: "item-1")
        XCTAssertEqual(store.item(itemID: "item-1")?.status, .downloading, "must actually have started for this to be a meaningful test")

        manager.delete(itemID: "item-1")

        XCTAssertEqual(cancelledItemIDs, ["item-1"])
    }

    /// The flip side: a row still `.queued` — never admitted, no real
    /// session ever started — must not fire a cancel at all, matching what
    /// the real (non-overridden) path does when `sessions` has no entry for
    /// it.
    func test_delete_queuedNeverStartedItem_doesNotInvokeCancelOverride() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        var cancelledItemIDs: [String] = []
        let manager = DownloadManager(
            store: store,
            preferences: makePreferences(maxConcurrentDownloads: 0),
            startVideoDownloadOverride: { _, _, _ in },
            cancelVideoDownloadOverride: { cancelledItemIDs.append($0) }
        )
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .queued, pendingDownloadURLString: "https://example.com/1"))
        // `maxConcurrentDownloads: 0` alone (Unlimited) would still admit
        // immediately — never call `queueVideoDownload` at all, so this row
        // stays `.queued` with no delegate/session ever created.

        manager.delete(itemID: "item-1")

        XCTAssertTrue(cancelledItemIDs.isEmpty)
    }
}
