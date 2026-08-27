import XCTest
@testable import Dionysus

@MainActor
final class DownloadsViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private func makeClient() -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

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

        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        viewModel.beginSelecting()

        XCTAssertTrue(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedRowIDs.isEmpty)
    }

    func test_cancelSelecting_clearsSelectionAndExitsSelectingMode() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        viewModel.toggleSelectAll()

        XCTAssertEqual(viewModel.selectedAssetCount, 4) // 3 episodes + 1 movie
    }

    func test_selectedAssetCount_zeroWithNothingSelected() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        XCTAssertEqual(viewModel.selectedAssetCount, 0)
    }

    func test_deleteSelected_standaloneItem_removesItAndExitsSelectionMode() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2"))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
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
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
        viewModel.beginSelecting()
        viewModel.toggleSelection("show-series-1")

        viewModel.deleteSelected()

        XCTAssertNil(store.item(itemID: "ep-1"))
        XCTAssertNil(store.item(itemID: "ep-2"))
        XCTAssertNotNil(store.item(itemID: "movie-1"))
    }

    // MARK: rowSizes / selectedTotalBytes — bulk-delete's per-row and total size readouts

    func test_rowSizes_standaloneCompletedItem_matchesOnDiskFileSize() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let item = DownloadTestHelpers.makeItem(itemID: "item-1", status: .completed)
        store.insert(item)
        try DownloadFileStore.write(Data(repeating: 0, count: 1_000), toRelativePath: item.videoFilePath)
        defer { DownloadFileStore.deleteItemFiles(itemID: "item-1") }

        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        XCTAssertEqual(viewModel.rowSizes["standalone-item-1"], 1_000)
    }

    /// A row still mid-download has no stable file size to show — excluded
    /// entirely (`0`, not whatever partial bytes happen to be on disk right
    /// now) rather than showing a number that's about to change.
    func test_rowSizes_downloadingItem_isZero() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let item = DownloadTestHelpers.makeItem(itemID: "item-1", status: .downloading)
        store.insert(item)
        try DownloadFileStore.write(Data(repeating: 0, count: 1_000), toRelativePath: item.videoFilePath)
        defer { DownloadFileStore.deleteItemFiles(itemID: "item-1") }

        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        XCTAssertEqual(viewModel.rowSizes["standalone-item-1"], 0)
    }

    /// A `.show` row sums every one of its completed episodes' own video
    /// files — the same total the group represents once selected for bulk
    /// delete.
    func test_rowSizes_showRow_sumsCompletedEpisodesOnly() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let ep1 = makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1)
        ep1.status = .completed
        let ep2 = makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2)
        ep2.status = .completed
        let ep3 = makeEpisode(itemID: "ep-3", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 3)
        ep3.status = .downloading // still in flight — excluded from the sum
        store.insert(ep1)
        store.insert(ep2)
        store.insert(ep3)
        try DownloadFileStore.write(Data(repeating: 0, count: 1_000), toRelativePath: ep1.videoFilePath)
        try DownloadFileStore.write(Data(repeating: 0, count: 2_000), toRelativePath: ep2.videoFilePath)
        try DownloadFileStore.write(Data(repeating: 0, count: 4_000), toRelativePath: ep3.videoFilePath)
        defer {
            DownloadFileStore.deleteItemFiles(itemID: "ep-1")
            DownloadFileStore.deleteItemFiles(itemID: "ep-2")
            DownloadFileStore.deleteItemFiles(itemID: "ep-3")
        }

        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        XCTAssertEqual(viewModel.rowSizes["show-series-1"], 3_000, "1,000 + 2,000 from the two completed episodes; ep-3 excluded")
    }

    func test_selectedTotalBytes_sumsAcrossSelection() throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        let item1 = DownloadTestHelpers.makeItem(itemID: "item-1", status: .completed)
        let item2 = DownloadTestHelpers.makeItem(itemID: "item-2", status: .completed)
        store.insert(item1)
        store.insert(item2)
        try DownloadFileStore.write(Data(repeating: 0, count: 1_000), toRelativePath: item1.videoFilePath)
        try DownloadFileStore.write(Data(repeating: 0, count: 2_000), toRelativePath: item2.videoFilePath)
        defer {
            DownloadFileStore.deleteItemFiles(itemID: "item-1")
            DownloadFileStore.deleteItemFiles(itemID: "item-2")
        }
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        viewModel.toggleSelectAll()

        XCTAssertEqual(viewModel.selectedTotalBytes, 3_000)
        XCTAssertEqual(viewModel.selectedTotalSizeText, FileSizeText.text(bytes: 3_000))
    }

    /// Nothing selected with a real completed size yet — the confirmation
    /// dialog should fall back to its plain count-only wording rather than
    /// claim a "0 bytes" deletion.
    func test_selectedTotalSizeText_nilWhenSelectionHasNoCompletedSize() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .downloading))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })

        viewModel.toggleSelectAll()

        XCTAssertNil(viewModel.selectedTotalSizeText)
    }

    // MARK: retry(itemID:client:) — the Downloads-list row's own retry
    // button (2026-08-27), wired to `DownloadManager.retry(itemID:client:)`.
    // As with `DownloadManagerTests`' own `retry` coverage, only the
    // branches that don't require `enqueue()`'s network-heavy internals to
    // run to completion are covered here.

    func test_retry_rowNotFailed_isNoOpAndMakesNoRequest() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .downloading))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
        MockURLProtocol.requestHandler = { _ in XCTFail("must not hit the network for a non-failed row"); throw URLError(.badURL) }

        await viewModel.retry(itemID: "item-1", client: makeClient())

        XCTAssertNil(viewModel.retryErrorMessage)
        XCTAssertTrue(viewModel.retryingItemIDs.isEmpty)
    }

    /// A network failure during retry surfaces through `retryErrorMessage`
    /// (what `DownloadsView`'s alert reads) rather than being swallowed —
    /// and `retryingItemIDs` still ends up empty afterward either way, so
    /// the row's retry button doesn't stay stuck disabled/spinning.
    func test_retry_networkFailure_setsRetryErrorMessageAndClearsRetryingState() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", status: .failed))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        await viewModel.retry(itemID: "item-1", client: makeClient())

        XCTAssertNotNil(viewModel.retryErrorMessage)
        XCTAssertTrue(viewModel.retryingItemIDs.isEmpty)
    }

    func test_deleteSelected_selectAll_removesEverything() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(store: store)
        store.insert(makeEpisode(itemID: "ep-1", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 1))
        store.insert(makeEpisode(itemID: "ep-2", seriesID: "series-1", seriesTitle: "A Show", episodeNumber: 2))
        store.insert(DownloadTestHelpers.makeItem(itemID: "movie-1"))
        let viewModel = DownloadsViewModel(downloadManager: manager, deferredDeleteScheduler: { $0() })
        viewModel.beginSelecting()
        viewModel.toggleSelectAll()

        viewModel.deleteSelected()

        XCTAssertTrue(store.visibleItems().isEmpty)
        XCTAssertTrue(viewModel.rows.isEmpty)
    }
}
