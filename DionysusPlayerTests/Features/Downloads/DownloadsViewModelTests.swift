import XCTest
@testable import Dionysus

@MainActor
final class DownloadsViewModelTests: XCTestCase {
    private func makeEpisode(itemID: String, seriesID: String, seriesTitle: String, episodeNumber: Int) -> DownloadedItem {
        let item = DownloadTestHelpers.makeItem(itemID: itemID)
        item.kind = .episode
        item.seriesID = seriesID
        item.seriesTitle = seriesTitle
        item.episodeNumber = episodeNumber
        item.episodeLabel = "S1:E\(episodeNumber)"
        return item
    }

    // MARK: rows — standalone vs. show grouping (existing behavior, sanity check)

    func test_refresh_groupsMultipleEpisodesIntoAShowRow() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1))
        store.insert(makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2))

        let viewModel = DownloadsViewModel(downloadManager: manager)

        XCTAssertEqual(viewModel.rows.count, 1)
        guard case .show(_, let title, _, let count) = viewModel.rows.first else {
            return XCTFail("expected a .show row")
        }
        XCTAssertEqual(title, "A Show")
        XCTAssertEqual(count, 2)
    }

    // MARK: Bulk selection

    func test_beginSelecting_startsWithNothingSelected() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)

        viewModel.beginSelecting()

        XCTAssertTrue(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedRowIDs.isEmpty)
    }

    func test_cancelSelecting_clearsSelectionAndExitsSelectingMode() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)
        viewModel.beginSelecting()
        viewModel.toggleSelection(viewModel.rows[0].id)

        viewModel.cancelSelecting()

        XCTAssertFalse(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedRowIDs.isEmpty)
    }

    func test_toggleSelection_addsThenRemoves() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)
        let rowID = viewModel.rows[0].id

        viewModel.toggleSelection(rowID)
        XCTAssertTrue(viewModel.selectedRowIDs.contains(rowID))

        viewModel.toggleSelection(rowID)
        XCTAssertFalse(viewModel.selectedRowIDs.contains(rowID))
    }

    func test_toggleSelectAll_selectsEveryRowThenDeselects() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2"))
        let viewModel = DownloadsViewModel(downloadManager: manager)

        viewModel.toggleSelectAll()
        XCTAssertTrue(viewModel.isAllSelected)
        XCTAssertEqual(viewModel.selectedRowIDs.count, 2)

        viewModel.toggleSelectAll()
        XCTAssertFalse(viewModel.isAllSelected)
        XCTAssertTrue(viewModel.selectedRowIDs.isEmpty)
    }

    func test_isAllSelected_falseWhenOnlySomeRowsSelected() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2"))
        let viewModel = DownloadsViewModel(downloadManager: manager)

        viewModel.toggleSelection(viewModel.rows[0].id)

        XCTAssertFalse(viewModel.isAllSelected)
    }

    /// The core new behavior: a selected show row's asset count is its
    /// *episode* count, not 1 — this is what the delete confirmation's "X
    /// total assets" figure has to get right.
    func test_selectedAssetCount_countsEveryEpisodeInASelectedShow() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1))
        store.insert(makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2))
        store.insert(makeEpisode(itemID: "ep-3", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 3))
        store.insert(DownloadTestHelpers.makeItem(itemID: "movie-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)

        viewModel.toggleSelectAll()

        XCTAssertEqual(viewModel.selectedAssetCount, 4) // 3 episodes + 1 movie
    }

    func test_selectedAssetCount_zeroWithNothingSelected() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)

        XCTAssertEqual(viewModel.selectedAssetCount, 0)
    }

    func test_deleteSelected_standaloneItem_removesItAndExitsSelectionMode() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2"))
        let viewModel = DownloadsViewModel(downloadManager: manager)
        viewModel.beginSelecting()
        viewModel.toggleSelection("standalone-item-1")

        viewModel.deleteSelected()

        XCTAssertNil(store.item(itemID: "item-1"))
        XCTAssertNotNil(store.item(itemID: "item-2"))
        XCTAssertFalse(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedRowIDs.isEmpty)
        XCTAssertEqual(viewModel.rows.count, 1)
    }

    /// Deleting a selected show row deletes *every* episode within it, not
    /// just the group row.
    func test_deleteSelected_showRow_removesEveryEpisode() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1))
        store.insert(makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2))
        store.insert(DownloadTestHelpers.makeItem(itemID: "movie-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)
        viewModel.beginSelecting()
        viewModel.toggleSelection("show-series-1")

        viewModel.deleteSelected()

        XCTAssertNil(store.item(itemID: "ep-1"))
        XCTAssertNil(store.item(itemID: "ep-2"))
        XCTAssertNotNil(store.item(itemID: "movie-1"))
    }

    func test_deleteSelected_selectAll_removesEverything() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1))
        store.insert(makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2))
        store.insert(DownloadTestHelpers.makeItem(itemID: "movie-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager)
        viewModel.beginSelecting()
        viewModel.toggleSelectAll()

        viewModel.deleteSelected()

        XCTAssertTrue(store.visibleItems().isEmpty)
        XCTAssertTrue(viewModel.rows.isEmpty)
    }
}
