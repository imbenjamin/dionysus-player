import XCTest
@testable import Dionysus

/// `DownloadFileStore` writes under the real `Application Support`
/// directory (see its own doc comment for why — never `Caches`), so these
/// tests clean up every file/itemID they touch in `tearDown` to avoid
/// leaking state across runs.
final class DownloadFileStoreTests: XCTestCase {
    private var touchedItemIDs: [String] = []
    private var touchedRelativePaths: [String] = []

    override func tearDown() {
        for itemID in touchedItemIDs { DownloadFileStore.deleteItemFiles(itemID: itemID) }
        for path in touchedRelativePaths { try? FileManager.default.removeItem(at: DownloadFileStore.url(forRelativePath: path)) }
        touchedItemIDs = []
        touchedRelativePaths = []
        super.tearDown()
    }

    private func uniqueItemID() -> String {
        let id = "DownloadFileStoreTests-\(UUID().uuidString)"
        touchedItemIDs.append(id)
        return id
    }

    // MARK: relative path helpers

    func test_videoRelativePath_isItemScoped() {
        XCTAssertEqual(DownloadFileStore.videoRelativePath(itemID: "abc"), "abc/video.mp4")
    }

    func test_subtitleRelativePath_includesIndexAndLanguage() {
        XCTAssertEqual(
            DownloadFileStore.subtitleRelativePath(itemID: "abc", index: 2, language: "eng", fileExtension: "srt"),
            "abc/subs/2-eng.srt"
        )
    }

    func test_subtitleRelativePath_missingLanguage_fallsBackToUnd() {
        XCTAssertEqual(
            DownloadFileStore.subtitleRelativePath(itemID: "abc", index: 0, language: nil, fileExtension: "vtt"),
            "abc/subs/0-und.vtt"
        )
    }

    func test_trickplayTileRelativePath_isItemAndWidthAndSheetScoped() {
        XCTAssertEqual(
            DownloadFileStore.trickplayTileRelativePath(itemID: "abc", width: 320, sheetIndex: 3),
            "abc/trickplay/320/3.jpg"
        )
    }

    func test_imageRelativePath_isContentAddressedNotItemScoped() {
        // Real Jellyfin item ids are plain hex GUIDs with no punctuation —
        // use one here so the separator hyphens this method inserts aren't
        // ambiguous with (sanitized-away) hyphens inside the id itself; see
        // `test_imageRelativePath_sanitizesHostileCharactersInComponents`
        // for that case specifically.
        let path = DownloadFileStore.imageRelativePath(sourceItemID: "series1", imageType: "Logo", tag: "tag123")
        XCTAssertEqual(path, "images/series1-Logo-tag123.jpg")
    }

    /// A component containing a character `sanitized(_:)` doesn't allow
    /// (anything non-alphanumeric, including a stray hyphen) gets it
    /// replaced with `_` rather than left as-is — keeps the three
    /// hyphen-joined components unambiguous from each other.
    func test_imageRelativePath_sanitizesHostileCharactersInComponents() {
        let path = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: "tag/123")
        XCTAssertEqual(path, "images/series_1-Logo-tag_123.jpg")
    }

    // MARK: write / moveFile / totalSizeOnDisk

    func test_write_thenFileExistsAtRelativePath() throws {
        let itemID = uniqueItemID()
        let relativePath = DownloadFileStore.videoRelativePath(itemID: itemID)
        try DownloadFileStore.write(Data("hello".utf8), toRelativePath: relativePath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: relativePath).path))
    }

    // MARK: fileSize — ground truth for DownloadedAssetDetailView's file-size readout

    func test_fileSize_matchesActualBytesWritten() throws {
        let itemID = uniqueItemID()
        let relativePath = DownloadFileStore.videoRelativePath(itemID: itemID)
        try DownloadFileStore.write(Data(repeating: 0, count: 1234), toRelativePath: relativePath)

        XCTAssertEqual(DownloadFileStore.fileSize(forRelativePath: relativePath), 1234)
    }

    func test_fileSize_nilForMissingFile() {
        XCTAssertNil(DownloadFileStore.fileSize(forRelativePath: "does/not/exist.mp4"))
    }

    func test_moveFile_movesSourceIntoPlace() throws {
        let itemID = uniqueItemID()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("moved".utf8).write(to: tempURL)

        let relativePath = DownloadFileStore.videoRelativePath(itemID: itemID)
        try DownloadFileStore.moveFile(from: tempURL, toRelativePath: relativePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try Data(contentsOf: DownloadFileStore.url(forRelativePath: relativePath)), Data("moved".utf8))
    }

    // MARK: imageAlreadyExists — fetch-time dedup

    func test_imageAlreadyExists_falseBeforeWrite_trueAfter() throws {
        let tag = "dedup-test-\(UUID().uuidString)"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: tag)
        touchedRelativePaths.append(relativePath)

        XCTAssertFalse(DownloadFileStore.imageAlreadyExists(sourceItemID: "series-1", imageType: "Logo", tag: tag))
        try DownloadFileStore.write(Data("logo".utf8), toRelativePath: relativePath)
        XCTAssertTrue(DownloadFileStore.imageAlreadyExists(sourceItemID: "series-1", imageType: "Logo", tag: tag))
    }

    // MARK: deleteItemFiles — unconditional, per-item

    func test_deleteItemFiles_removesVideoAndSubs() throws {
        let itemID = uniqueItemID()
        try DownloadFileStore.write(Data("video".utf8), toRelativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
        try DownloadFileStore.write(Data("sub".utf8), toRelativePath: DownloadFileStore.subtitleRelativePath(itemID: itemID, index: 0, language: "eng", fileExtension: "srt"))

        DownloadFileStore.deleteItemFiles(itemID: itemID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: DownloadFileStore.videoRelativePath(itemID: itemID)).path))
    }

    // MARK: deleteImageIfUnreferenced — the shared-artwork delete guard

    @MainActor
    func test_deleteImageIfUnreferenced_stillReferenced_leavesFileInPlace() throws {
        let tag = "shared-\(UUID().uuidString)"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: tag)
        touchedRelativePaths.append(relativePath)
        try DownloadFileStore.write(Data("logo".utf8), toRelativePath: relativePath)

        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: relativePath))
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-2", logoImagePath: relativePath))

        DownloadFileStore.deleteImageIfUnreferenced(relativePath: relativePath, excludingItemID: "ep-1", store: store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: relativePath).path))
    }

    @MainActor
    func test_deleteImageIfUnreferenced_lastReference_removesFile() throws {
        let tag = "unshared-\(UUID().uuidString)"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: "series-1", imageType: "Logo", tag: tag)
        touchedRelativePaths.append(relativePath)
        try DownloadFileStore.write(Data("logo".utf8), toRelativePath: relativePath)

        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "ep-1", logoImagePath: relativePath))

        DownloadFileStore.deleteImageIfUnreferenced(relativePath: relativePath, excludingItemID: "ep-1", store: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadFileStore.url(forRelativePath: relativePath).path))
    }

    @MainActor
    func test_deleteImageIfUnreferenced_nilPath_isNoOp() {
        let store = DownloadTestHelpers.makeInMemoryStore()
        // Should simply not crash / not throw with a nil path.
        DownloadFileStore.deleteImageIfUnreferenced(relativePath: nil, excludingItemID: "ep-1", store: store)
    }
}
