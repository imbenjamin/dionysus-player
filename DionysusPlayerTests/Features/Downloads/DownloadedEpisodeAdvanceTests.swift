import XCTest
@testable import Dionysus

/// What a downloaded episode's page does once its player closes on an advance
/// (#274): delete the finished download only when the viewer chose Delete &
/// Play Next, then play the next download, or settle on a page that still
/// has something to show.
@MainActor
final class DownloadedEpisodeAdvanceTests: XCTestCase {
    private var touchedItemIDs: [String] = []

    override func tearDown() async throws {
        for itemID in touchedItemIDs { DownloadFileStore.deleteItemFiles(itemID: itemID) }
        touchedItemIDs = []
        try await super.tearDown()
    }

    private func completed(_ itemID: String) -> DownloadedItem {
        DownloadTestHelpers.makeItem(itemID: itemID, status: .completed, kind: .episode)
    }

    private func storeWith(_ itemIDs: [String]) -> DownloadStore {
        let store = DownloadTestHelpers.makeInMemoryStore()
        for itemID in itemIDs { store.insert(completed(itemID)) }
        return store
    }

    func test_deleteAndPlayNext_deletesFinished_andPlaysNext() {
        let store = storeWith(["e1", "e2"])
        var deleted: [String] = []
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: true)

        let outcome = advance.resolve(store: store) { deleted.append($0) }

        XCTAssertEqual(deleted, ["e1"])
        XCTAssertEqual(outcome, .play("e2"))
    }

    func test_countdown_deletesNothing_andPlaysNext() {
        let store = storeWith(["e1", "e2"])
        var deleted: [String] = []
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: false)

        let outcome = advance.resolve(store: store) { deleted.append($0) }

        XCTAssertTrue(deleted.isEmpty, "Only Delete & Play Next deletes")
        XCTAssertEqual(outcome, .play("e2"))
    }

    func test_nextGone_finishedKept_staysOnFinished() {
        let store = storeWith(["e1"])
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: false)

        XCTAssertEqual(advance.resolve(store: store) { _ in }, .stay("e1"))
    }

    func test_nextGone_finishedDeleted_leaves() {
        let store = storeWith(["e1"])
        let manager = DownloadManager(store: store)
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: true)

        XCTAssertEqual(advance.resolve(store: store, delete: manager.delete(itemID:)), .leave)
    }

    func test_nextMarkedForDeletion_isNotPlayed() {
        let store = storeWith(["e1"])
        store.insert(DownloadTestHelpers.makeItem(itemID: "e2", markedForDeletion: true, status: .completed, kind: .episode))
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: false)

        XCTAssertEqual(advance.resolve(store: store) { _ in }, .stay("e1"))
    }

    /// The deleted episode's watched mark hasn't synced yet: the row survives
    /// as `markedForDeletion` with `isPlayed` kept, its file gone, and the page
    /// moves on rather than staying on it.
    func test_deletingAnUnsyncedWatchedEpisode_keepsItsWatchedMarkUntilSync() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let finished = DownloadTestHelpers.makeItem(itemID: "e1", pendingSync: true, status: .completed, kind: .episode)
        finished.isPlayed = true
        store.insert(finished)
        store.insert(completed("e2"))
        touchedItemIDs = ["e1", "e2"]
        try DownloadFileStore.write(Data("video".utf8), toRelativePath: DownloadFileStore.videoRelativePath(itemID: "e1"))
        let advance = DownloadedEpisodeAdvance(finishedItemID: "e1", nextItemID: "e2", deletesFinished: true)

        let outcome = advance.resolve(store: store, delete: manager.delete(itemID:))

        XCTAssertEqual(outcome, .play("e2"))
        let row = try XCTUnwrap(store.item(itemID: "e1"), "The row waits for its sync")
        XCTAssertTrue(row.markedForDeletion)
        XCTAssertTrue(row.isPlayed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: "e1")).path
        ))
    }
}
