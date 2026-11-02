import XCTest
@testable import Dionysus

/// The Top Shelf's composited art (M6): tvOS 27 draws no text over a
/// third-party carousel, so the title's logo (or name), the context line and
/// a resume bar are drawn into the image (Benjamin, 2026-10-14).
final class TopShelfArtworkLayoutTests: XCTestCase {
    private let canvas = TopShelfArtworkLayout.canvas

    /// Above the app dock (compact shelf) and left of the Play/More Info
    /// buttons (full screen), both of which cover the bottom of the image.
    func test_block_staysClearOfTheDockAndTheButtons() {
        for logo in [CGSize(width: 800, height: 310), CGSize(width: 400, height: 400), CGSize(width: 1000, height: 100)] {
            let rect = TopShelfArtworkLayout.logoRect(logoSize: logo)
            XCTAssertLessThanOrEqual(rect.maxY, canvas.height * TopShelfArtworkLayout.blockBottom)
            XCTAssertLessThanOrEqual(rect.maxX, canvas.width * 0.38)
            XCTAssertGreaterThanOrEqual(rect.minX, canvas.width * 0.10, "Clear of full screen's left arrow")
        }
        XCTAssertLessThanOrEqual(TopShelfArtworkLayout.remainingRect.maxY, canvas.height * TopShelfArtworkLayout.blockBottom)
        XCTAssertLessThanOrEqual(TopShelfArtworkLayout.contextRect.maxY, TopShelfArtworkLayout.remainingRect.minY)
    }

    func test_logo_keepsItsAspect_andSitsOnTheBaseline() {
        let wide = TopShelfArtworkLayout.logoRect(logoSize: CGSize(width: 800, height: 200))
        XCTAssertEqual(wide.width / wide.height, 4, accuracy: 0.01)
        let tall = TopShelfArtworkLayout.logoRect(logoSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(tall.width / tall.height, 1, accuracy: 0.01)
        XCTAssertEqual(wide.maxY, tall.maxY, accuracy: 0.5, "Every logo ends on the same line above the context")
        XCTAssertEqual(wide.minX, tall.minX, accuracy: 0.5)
    }

    private static func jpeg(width: Int, height: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The extension has about 22MB on Bedroom (measured 2026-10-14): the art
    /// is drawn from the backdrop's compressed bytes into one canvas and
    /// handed back as JPEG, never as decoded images.
    func test_render_isAJPEGTheCanvasSize() throws {
        let data = try XCTUnwrap(TopShelfArtworkRenderer.render(
            backdrop: Self.jpeg(width: 1280, height: 720), logo: nil,
            title: "Arrival", context: "Continue Watching", remaining: "1h 45m remaining"
        ))
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size, canvas)
    }

    /// 1280 wide (Benjamin, 2026-10-14): 1920 died every time on Bedroom and
    /// 1600 left about a megabyte; two 1280 bitmaps and an 8MB margin must
    /// still fit what's free, or nothing is drawn.
    func test_pixelWidth_is1280_whenItFits() {
        XCTAssertEqual(TopShelfArtworkRenderer.pixelWidth(availableBytes: 0), 1280, "No limit (Simulator)")
        XCTAssertEqual(TopShelfArtworkRenderer.pixelWidth(availableBytes: 40 << 20), 1280)
        XCTAssertEqual(TopShelfArtworkRenderer.pixelWidth(availableBytes: 17 << 20), 1280, "Bedroom after a download")
        XCTAssertNil(TopShelfArtworkRenderer.pixelWidth(availableBytes: 12 << 20), "Too little: keep the plain backdrop")
    }

    func test_render_atASmallerWidth_keepsTheShape() throws {
        let data = try XCTUnwrap(TopShelfArtworkRenderer.render(
            backdrop: Self.jpeg(width: 1920, height: 1080), logo: nil,
            title: "Arrival", context: "Continue Watching", remaining: nil, pixelWidth: 1280
        ))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: data)).size, CGSize(width: 1280, height: 720))
    }

    func test_render_withALogo() throws {
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100)).pngData { _ in }
        XCTAssertNotNil(TopShelfArtworkRenderer.render(
            backdrop: Self.jpeg(width: 1920, height: 1080), logo: logo,
            title: "Arrival", context: "Next Up", remaining: nil
        ))
    }

    func test_render_isNil_forBytesThatArentAnImage() {
        XCTAssertNil(TopShelfArtworkRenderer.render(
            backdrop: Data("not an image".utf8), logo: nil, title: "A", context: "B", remaining: nil
        ))
    }
}

final class TopShelfArtworkStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TopShelfArtworkStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = TopShelfArtworkStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var image: Data { Data([0xFF, 0xD8, 0xFF]) }

    func test_write_thenFindsIt() throws {
        XCTAssertNil(store.existing(for: "k1"))
        let url = try XCTUnwrap(store.write(image, for: "k1"))
        XCTAssertEqual(store.existing(for: "k1"), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_prune_keepsOnlyWhatTheShelfStillShows() throws {
        _ = store.write(image, for: "k1")
        _ = store.write(image, for: "k2")
        store.prune(keeping: ["k2"])
        XCTAssertNil(store.existing(for: "k1"))
        XCTAssertNotNil(store.existing(for: "k2"))
    }
}
