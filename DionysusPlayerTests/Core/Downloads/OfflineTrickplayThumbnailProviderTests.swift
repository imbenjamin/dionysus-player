import UIKit
import XCTest
@testable import Dionysus

/// `OfflineTrickplayThumbnailProvider` — same seconds→tile math as
/// `TrickplayThumbnailProviderTests` (the live counterpart), but reading a
/// sheet already written to `DownloadFileStore` instead of mocking a
/// network fetch.
@MainActor
final class OfflineTrickplayThumbnailProviderTests: XCTestCase {
    private var touchedItemIDs: [String] = []

    // `async throws` override, not the plain synchronous one: XCTestCase's
    // synchronous `tearDown()` is nonisolated in the framework overlay, so an
    // override must match that regardless of this class's own `@MainActor`
    // — touching `touchedItemIDs` (MainActor-isolated) there would warn.
    // The async override runs genuinely on the main actor.
    override func tearDown() async throws {
        for itemID in touchedItemIDs { DownloadFileStore.deleteItemFiles(itemID: itemID) }
        touchedItemIDs = []
        try await super.tearDown()
    }

    private func uniqueItemID() -> String {
        let id = "OfflineTrickplayThumbnailProviderTests-\(UUID().uuidString)"
        touchedItemIDs.append(id)
        return id
    }

    /// A 2×2-tile sheet (each tile 4×4) — same fixture shape
    /// `TrickplayThumbnailProviderTests.makeSheetImageData()` uses, small
    /// enough to decode instantly, big enough to confirm cropping actually
    /// happened rather than just returning the whole sheet.
    private nonisolated static func makeSheetImageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData()!
    }

    func test_thumbnail_readsWrittenSheetAndReturnsCroppedTileSize() async throws {
        let itemID = uniqueItemID()
        let info = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 4, interval: 1000, bandwidth: 1)
        try DownloadFileStore.write(
            Self.makeSheetImageData(),
            toRelativePath: DownloadFileStore.trickplayTileRelativePath(itemID: itemID, width: 4, sheetIndex: 0)
        )
        let provider = OfflineTrickplayThumbnailProvider(itemID: itemID, info: info)

        let image = await provider.thumbnail(atSeconds: 1)
        let result = try XCTUnwrap(image)

        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
    }

    func test_thumbnail_missingSheetFile_returnsNil() async {
        let itemID = uniqueItemID()
        let info = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 4, interval: 1000, bandwidth: 1)
        // No sheet written for this item at all — mirrors a sheet that
        // failed its best-effort fetch at enqueue time.
        let provider = OfflineTrickplayThumbnailProvider(itemID: itemID, info: info)

        let result = await provider.thumbnail(atSeconds: 1)

        XCTAssertNil(result)
    }

    func test_thumbnail_degenerateInfo_returnsNil() async {
        let itemID = uniqueItemID()
        let degenerate = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 0, interval: 1000, bandwidth: 0)
        let provider = OfflineTrickplayThumbnailProvider(itemID: itemID, info: degenerate)

        let result = await provider.thumbnail(atSeconds: 1)

        XCTAssertNil(result)
    }
}
