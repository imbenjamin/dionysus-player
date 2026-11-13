import XCTest
@testable import Dionysus

final class SubtitleOverlayLayoutTests: XCTestCase {
    /// The phone's values are the ones the overlay always had.
    func test_phoneMetrics_areUnchanged() {
        let phone = SubtitleOverlayMetrics.phone
        XCTAssertEqual(phone.fontSize, 20)
        XCTAssertEqual(phone.horizontalInset, 24)
        XCTAssertEqual(phone.restingBottomInset, 28)
        XCTAssertEqual(phone.controlsGap, 8)
    }

    /// Matched to Infuse's default on the same scene of Saving Private Ryan,
    /// photographed from the sofa (Bedroom Apple TV, 2026-10-08).
    func test_tvFontSize_matchesInfuse() {
        XCTAssertEqual(SubtitleOverlayMetrics.tv.fontSize, 54)
    }

    func test_bottomInset_clearsTheChrome_andRestsWithoutIt() {
        let tv = SubtitleOverlayMetrics.tv
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            1080 - 860 + tv.controlsGap
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: false, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: .infinity, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset, "No chrome reported, nothing to clear"
        )
    }
}

/// `SubtitleOverlayView.pictureRect` and `imageCueFrame`: cues are placed
/// against the displayed picture, and a bitmap canvas maps onto the coded
/// frame before it scales onto that picture (AetherEngine's `SubtitleImage`
/// contract, stated from 7.59.0).
final class SubtitlePictureGeometryTests: XCTestCase {
    private let pal = CGSize(width: 720, height: 576)
    private let palWide = 64.0 / 45.0

    func test_pictureRect_takesTheDisplayedShape_ofAnamorphicVideo() {
        let rect = SubtitleOverlayView.pictureRect(
            in: CGSize(width: 1920, height: 1080), codedSize: pal, pixelAspectRatio: palWide, zoomMode: .fit
        )
        XCTAssertEqual(rect.width, 1920, accuracy: 0.01)
        XCTAssertEqual(rect.height, 1080, accuracy: 0.01, "720×576 at 64:45 is 16:9 and fills a 16:9 screen")
    }

    func test_pictureRect_isUnchanged_forSquarePixels() {
        let rect = SubtitleOverlayView.pictureRect(
            in: CGSize(width: 390, height: 844), codedSize: CGSize(width: 3840, height: 1600),
            pixelAspectRatio: 1, zoomMode: .fit
        )
        XCTAssertEqual(rect.width, 390, accuracy: 0.01)
        XCTAssertEqual(rect.height, 162.5, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 422, accuracy: 0.01)
    }

    func test_pictureRect_fill_coversTheContainer_inTheDisplayedShape() {
        let rect = SubtitleOverlayView.pictureRect(
            in: CGSize(width: 1000, height: 1000), codedSize: pal, pixelAspectRatio: palWide, zoomMode: .fill
        )
        XCTAssertEqual(rect.height, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1000 * 16 / 9, accuracy: 0.01)
    }

    func test_pictureRect_treatsAMissingRatio_asSquare() {
        let rect = SubtitleOverlayView.pictureRect(
            in: CGSize(width: 1920, height: 1080), codedSize: pal, pixelAspectRatio: 0, zoomMode: .fit
        )
        XCTAssertEqual(rect.width / rect.height, 720.0 / 576.0, accuracy: 0.001)
    }

    /// A DVB or DVD plane reported as the coded frame covers the anamorphic
    /// picture exactly. Mapped width-aligned onto the displayed picture, the
    /// canvas was 1.42 times too tall and a bottom cue fell below the picture.
    func test_imageCue_onAnamorphicVideo_mapsTheCodedFrameOntoThePicture() {
        let picture = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = SubtitleOverlayView.imageCueFrame(
            position: CGRect(x: 0.3, y: 0.9, width: 0.4, height: 0.08),
            canvasSize: pal, codedSize: pal, picture: picture
        )
        XCTAssertEqual(frame.minX, 576, accuracy: 0.01)
        XCTAssertEqual(frame.minY, 972, accuracy: 0.01)
        XCTAssertEqual(frame.width, 768, accuracy: 0.01)
        XCTAssertEqual(frame.height, 86.4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(frame.maxY, picture.maxY + 0.01, "The cue stays on the picture")
    }

    /// A 16:9 PGS canvas over a 2.4:1 square-pixel picture: taller than the
    /// picture, width-aligned and centred, as before.
    func test_imageCue_onSquarePixels_keepsTheWidthAlignedCanvas() {
        let picture = CGRect(x: 0, y: 340, width: 390, height: 162.5)
        let frame = SubtitleOverlayView.imageCueFrame(
            position: CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.08),
            canvasSize: CGSize(width: 1920, height: 1080), codedSize: CGSize(width: 3840, height: 1600),
            picture: picture
        )
        let canvasHeight = 390.0 * 1080 / 1920
        XCTAssertEqual(frame.height, 0.08 * canvasHeight, accuracy: 0.01)
        XCTAssertEqual(frame.minY, picture.midY - canvasHeight / 2 + 0.7 * canvasHeight, accuracy: 0.01)
        XCTAssertEqual(frame.minX, 117, accuracy: 0.01)
    }

    /// A taller canvas than the coded frame on anamorphic video (cropped
    /// before scaling): width-aligned on the coded frame, then scaled.
    func test_imageCue_tallerCanvasOnAnamorphicVideo_scalesPerAxis() {
        let picture = CGRect(x: 0, y: 0, width: 1024, height: 576)
        let frame = SubtitleOverlayView.imageCueFrame(
            position: CGRect(x: 0, y: 0, width: 1, height: 1),
            canvasSize: CGSize(width: 720, height: 720), codedSize: pal, picture: picture
        )
        XCTAssertEqual(frame.height, 720, accuracy: 0.01, "720 coded lines tall, at one picture point per coded line")
        XCTAssertEqual(frame.midY, picture.midY, accuracy: 0.01)
        XCTAssertEqual(frame.width, 1024, accuracy: 0.01)
    }

    func test_imageCue_withAnUnknownCanvas_isThePicture() {
        let picture = CGRect(x: 10, y: 20, width: 300, height: 100)
        let frame = SubtitleOverlayView.imageCueFrame(
            position: CGRect(x: 0, y: 0, width: 1, height: 1), canvasSize: .zero, codedSize: pal, picture: picture
        )
        XCTAssertEqual(frame, picture)
    }
}
