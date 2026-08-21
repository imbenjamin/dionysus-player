import XCTest
@testable import Dionysus

@MainActor
final class DownloadStoreTests: XCTestCase {
    func test_insert_thenItem_returnsIt() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))

        XCTAssertEqual(store.item(itemID: "item-1")?.itemID, "item-1")
        XCTAssertNil(store.item(itemID: "missing"))
    }

    func test_delete_removesRow() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        store.delete(item)

        XCTAssertNil(store.item(itemID: "item-1"))
    }

    // MARK: changeCount (2026-08-20) — the Observation-tracking fix for
    // views computing `store.item(itemID:)`/etc. directly in a `var`,
    // which a raw SwiftData fetch alone doesn't give SwiftUI anything to
    // track. See its own doc comment for the real "view stuck on stale
    // data" bug this fixes.

    func test_changeCount_incrementsOnInsertAndDelete() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let initial = store.changeCount
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")

        store.insert(item)
        XCTAssertEqual(store.changeCount, initial + 1)

        store.delete(item)
        XCTAssertEqual(store.changeCount, initial + 2)
    }

    /// `save()` is the actual choke point every mutation funnels through
    /// (including ones that mutate a row's properties in place, like a
    /// status transition, rather than inserting/deleting a whole row) —
    /// confirms it bumps `changeCount` too, not just `insert`/`delete`.
    func test_changeCount_incrementsOnPlainSave() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let afterInsert = store.changeCount

        store.item(itemID: "item-1")?.errorMessage = "changed"
        store.save()

        XCTAssertEqual(store.changeCount, afterInsert + 1)
    }

    // MARK: items(itemIDs:) — the batched-fetch overload (2026-08-20
    // branch review), for a caller checking several known ids at once
    // instead of one `item(itemID:)` call per id in a loop.

    func test_itemsWithIDs_returnsOnlyTheMatchingRows() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "wanted-1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "wanted-2"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "not-wanted"))

        let result = store.items(itemIDs: ["wanted-1", "wanted-2"])

        XCTAssertEqual(Set(result.map(\.itemID)), ["wanted-1", "wanted-2"])
    }

    func test_itemsWithIDs_idWithNoRow_isSimplyAbsentFromTheResult() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "exists"))

        let result = store.items(itemIDs: ["exists", "does-not-exist"])

        XCTAssertEqual(result.map(\.itemID), ["exists"])
    }

    // MARK: visibleItems / allItems — markedForDeletion filtering

    func test_visibleItems_excludesMarkedForDeletion() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "visible"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "deleted", markedForDeletion: true))

        XCTAssertEqual(store.visibleItems().map(\.itemID), ["visible"])
        XCTAssertEqual(Set(store.allItems().map(\.itemID)), ["visible", "deleted"])
    }

    // MARK: pendingSyncItems

    func test_pendingSyncItems_includesMarkedForDeletionRows() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "not-pending"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "pending", pendingSync: true))
        store.insert(DownloadTestHelpers.makeItem(itemID: "pending-and-deleted", pendingSync: true, markedForDeletion: true))

        XCTAssertEqual(Set(store.pendingSyncItems().map(\.itemID)), ["pending", "pending-and-deleted"])
    }

    // MARK: isImagePathReferenced — the shared-artwork dedup's reference check

    func test_isImagePathReferenced_trueWhenAnotherItemSharesThePath() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: "images/series-Logo-tag.jpg"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-2", logoImagePath: "images/series-Logo-tag.jpg"))

        XCTAssertTrue(store.isImagePathReferenced("images/series-Logo-tag.jpg", excludingItemID: "ep-1"))
    }

    func test_isImagePathReferenced_falseWhenOnlyExcludedItemReferencesIt() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: "images/series-Logo-tag.jpg"))

        XCTAssertFalse(store.isImagePathReferenced("images/series-Logo-tag.jpg", excludingItemID: "ep-1"))
    }

    /// A `markedForDeletion` row's own stored image path still "counts" as
    /// a reference until the row itself is actually removed — see the
    /// offline-downloads plan's "Delete semantics" section.
    func test_isImagePathReferenced_trueEvenWhenReferencingRowIsMarkedForDeletion() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: "images/series-Logo-tag.jpg"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-2", markedForDeletion: true, logoImagePath: "images/series-Logo-tag.jpg"))

        XCTAssertTrue(store.isImagePathReferenced("images/series-Logo-tag.jpg", excludingItemID: "ep-1"))
    }

    func test_isImagePathReferenced_checksAllFourImageFields() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", posterImagePath: "images/a.jpg"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-2", backdropImagePath: "images/b.jpg"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-3", thumbImagePath: "images/c.jpg"))

        XCTAssertTrue(store.isImagePathReferenced("images/a.jpg", excludingItemID: "other"))
        XCTAssertTrue(store.isImagePathReferenced("images/b.jpg", excludingItemID: "other"))
        XCTAssertTrue(store.isImagePathReferenced("images/c.jpg", excludingItemID: "other"))
    }
}
