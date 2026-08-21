import UIKit
import XCTest
@testable import Dionysus

final class TrickplayMathTests: XCTestCase {
    private let info = TrickplayInfo(
        width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 1017, interval: 10000, bandwidth: 14011
    )

    // MARK: frame(atSeconds:info:)

    func test_frame_atZeroSeconds_isSheetZeroTopLeftTile() throws {
        let frame = try XCTUnwrap(TrickplayMath.frame(atSeconds: 0, info: info))
        XCTAssertEqual(frame.sheetIndex, 0)
        XCTAssertEqual(frame.tileRect, CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    func test_frame_midSheet_picksExpectedRowAndColumn() throws {
        // 10s interval, index 23 -> seconds in [230, 240). Sheet 0 (index < 100),
        // position 23 -> row 2, column 3.
        let frame = try XCTUnwrap(TrickplayMath.frame(atSeconds: 235, info: info))
        XCTAssertEqual(frame.sheetIndex, 0)
        XCTAssertEqual(frame.tileRect, CGRect(x: 3 * 320, y: 2 * 180, width: 320, height: 180))
    }

    func test_frame_crossingSheetBoundary_incrementsSheetIndexAndResetsPosition() throws {
        // Index 100 is the first thumbnail of sheet 1 (100 thumbnails/sheet), top-left tile.
        let frame = try XCTUnwrap(TrickplayMath.frame(atSeconds: 1000, info: info))
        XCTAssertEqual(frame.sheetIndex, 1)
        XCTAssertEqual(frame.tileRect, CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    func test_frame_pastRuntime_clampsToLastThumbnail() throws {
        // thumbnailCount=1017 -> last index 1016 -> sheet 10, position 16 -> row 1, column 6.
        let frame = try XCTUnwrap(TrickplayMath.frame(atSeconds: 999_999, info: info))
        XCTAssertEqual(frame.sheetIndex, 10)
        XCTAssertEqual(frame.tileRect, CGRect(x: 6 * 320, y: 1 * 180, width: 320, height: 180))
    }

    func test_frame_degenerateInfo_returnsNil() {
        let degenerate = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 0, interval: 10000, bandwidth: 0)
        XCTAssertNil(TrickplayMath.frame(atSeconds: 0, info: degenerate))
    }

    // MARK: sheetCount(for:)

    func test_sheetCount_exactMultipleOfPerSheet_noPartialSheet() {
        // 100 thumbnails/sheet (10x10), thumbnailCount 1017 -> ceil(1017/100) = 11.
        XCTAssertEqual(TrickplayMath.sheetCount(for: info), 11)
    }

    func test_sheetCount_singleFullSheet() {
        let single = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 100, interval: 10000, bandwidth: 1)
        XCTAssertEqual(TrickplayMath.sheetCount(for: single), 1)
    }

    func test_sheetCount_degenerateInfo_isZero() {
        let degenerate = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 0, interval: 10000, bandwidth: 0)
        XCTAssertEqual(TrickplayMath.sheetCount(for: degenerate), 0)
    }

    // MARK: bestInfo(from:mediaSourceID:preferredWidth:)

    func test_bestInfo_missingMediaSourceID_returnsNil() {
        XCTAssertNil(TrickplayMath.bestInfo(from: ["src-1": ["320": info]], mediaSourceID: nil))
    }

    func test_bestInfo_noEntryForMediaSourceID_returnsNil() {
        XCTAssertNil(TrickplayMath.bestInfo(from: ["src-1": ["320": info]], mediaSourceID: "src-2"))
    }

    func test_bestInfo_exactPreferredWidthMatch_isReturned() {
        let result = TrickplayMath.bestInfo(from: ["src-1": ["320": info]], mediaSourceID: "src-1", preferredWidth: 320)
        XCTAssertEqual(result, info)
    }

    func test_bestInfo_noneMeetPreferredWidth_fallsBackToWidest() {
        let small = TrickplayInfo(width: 160, height: 90, tileWidth: 10, tileHeight: 10, thumbnailCount: 100, interval: 10000, bandwidth: 1)
        let result = TrickplayMath.bestInfo(from: ["src-1": ["160": small]], mediaSourceID: "src-1", preferredWidth: 320)
        XCTAssertEqual(result, small)
    }

    func test_bestInfo_multipleWidths_picksSmallestThatMeetsPreferred() {
        let small = TrickplayInfo(width: 160, height: 90, tileWidth: 10, tileHeight: 10, thumbnailCount: 100, interval: 10000, bandwidth: 1)
        let large = TrickplayInfo(width: 640, height: 360, tileWidth: 10, tileHeight: 10, thumbnailCount: 100, interval: 10000, bandwidth: 1)
        let result = TrickplayMath.bestInfo(
            from: ["src-1": ["160": small, "320": info, "640": large]], mediaSourceID: "src-1", preferredWidth: 200
        )
        XCTAssertEqual(result, info)
    }
}

final class TrickplayThumbnailProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A 2×2-tile sheet (each tile 4×4) — small enough to render/decode
    /// instantly, big enough to confirm cropping actually happened rather
    /// than just returning the whole sheet.
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

    func test_thumbnail_fetchesExpectedSheetURLAndReturnsCroppedTileSize() async throws {
        let info = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 4, interval: 1000, bandwidth: 1)
        var requestedPath: String?
        MockURLProtocol.requestHandler = { [data = Self.makeSheetImageData()] request in
            requestedPath = request.url?.path
            return MockURLProtocol.jsonResponse(for: request, body: data)
        }
        let provider = TrickplayThumbnailProvider(
            itemID: "item-1", info: info,
            imageURLBuilder: ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok"),
            imageLoader: RemoteImageLoader(session: MockURLProtocol.makeSession())
        )

        let image = await provider.thumbnail(atSeconds: 1)
        let result = try XCTUnwrap(image)

        XCTAssertEqual(requestedPath, "/Videos/item-1/Trickplay/4/0.jpg")
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
    }

    func test_thumbnail_requestFailure_returnsNil() async {
        let info = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 4, interval: 1000, bandwidth: 1)
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }
        let provider = TrickplayThumbnailProvider(
            itemID: "item-1", info: info,
            imageURLBuilder: ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok"),
            imageLoader: RemoteImageLoader(session: MockURLProtocol.makeSession(), maxAttempts: 1)
        )

        let result = await provider.thumbnail(atSeconds: 1)

        XCTAssertNil(result)
    }
}
