import CoreGraphics
import XCTest
@testable import Dionysus

/// The geometry handed to libass, which is subtle enough in two places to be
/// worth pinning: the frame starts at the picture rather than the overlay, and
/// the margins are signed.
///
/// Both exist because `ass_set_use_margins` — what puts regular dialogue in the
/// bar below the picture — relocates *every* regular event into the margins.
/// Getting either wrong misplaces signs rather than breaking anything loudly,
/// which is the kind of thing that ships.
@MainActor
final class ASSSubtitleGeometryTests: XCTestCase {
    private let scale: CGFloat = 3

    /// iPhone-shaped portrait: a 16:9 picture letterboxed into a tall overlay,
    /// so there really is empty space above and below it.
    private func portrait(bottomInset: CGFloat) -> ASSSubtitleRenderSession.Geometry {
        ASSSubtitleRenderSession.Geometry(
            frame: CGSize(width: 402, height: 874),
            video: CGRect(x: 0, y: 323.94, width: 402, height: 226.13),
            bottomInset: bottomInset,
            scale: scale
        )
    }

    /// The same device rotated: the picture now fits to height and fills the
    /// screen vertically, pillarboxed instead. There is no bar below it, so the
    /// frame — which stops short of the transport chrome — is *shorter* than
    /// the picture.
    private func landscape(bottomInset: CGFloat) -> ASSSubtitleRenderSession.Geometry {
        ASSSubtitleRenderSession.Geometry(
            frame: CGSize(width: 874, height: 402),
            video: CGRect(x: 79.6, y: 0, width: 714.8, height: 402),
            bottomInset: bottomInset,
            scale: scale
        )
    }

    // MARK: - Frame origin

    /// The frame starts at the picture's top edge so there is no top margin for
    /// a top-aligned sign to be relocated into.
    func test_portrait_frameStartsAtThePictureNotTheOverlay() {
        let geometry = portrait(bottomInset: 28)
        XCTAssertEqual(geometry.renderOriginY, 323.94, accuracy: 0.01)
        XCTAssertEqual(geometry.margins.top, 0)
    }

    /// In landscape the picture already starts at the overlay's top, so the
    /// shift is a no-op — and the top margin is zero for the same reason.
    func test_landscape_frameAlreadyStartsAtThePicture() {
        let geometry = landscape(bottomInset: 28)
        XCTAssertEqual(geometry.renderOriginY, 0)
        XCTAssertEqual(geometry.margins.top, 0)
    }

    // MARK: - Signed bottom margin

    /// Portrait has real empty space below the picture, so the margin is
    /// positive and regular dialogue has somewhere to be relocated to.
    func test_portrait_bottomMarginIsPositive() {
        let geometry = portrait(bottomInset: 28)
        // Frame runs from the picture's top (323.94) to 874 - 28; the picture
        // ends at 550.07, leaving 295.99pt of bar.
        XCTAssertEqual(geometry.margins.bottom, Int32((295.99 * 3).rounded()))
        XCTAssertGreaterThan(geometry.margins.bottom, 0)
    }

    /// Landscape has none: the picture fills the screen, so the frame is
    /// shorter than the picture and the margin must go NEGATIVE — libass reads
    /// that as "the frame is inside the video". Clamping it to zero told libass
    /// the picture ended where the frame does, which mapped every `\pos` sign
    /// into a too-short rectangle.
    func test_landscape_bottomMarginIsNegative() {
        let geometry = landscape(bottomInset: 124)
        // Frame is 402 - 124 = 278 tall against a 402pt picture.
        XCTAssertEqual(geometry.margins.bottom, Int32(((278.0 - 402.0) * 3).rounded()))
        XCTAssertLessThan(geometry.margins.bottom, 0)
    }

    /// The picture's height is recoverable from frame + margins, which is what
    /// libass uses to map positioned events. It has to come out right in both
    /// orientations, whichever sign the margin took.
    func test_pictureHeightIsRecoverableFromFrameAndMargins() {
        for (name, geometry) in [
            ("portrait", portrait(bottomInset: 28)),
            ("portrait, controls up", portrait(bottomInset: 132)),
            ("landscape", landscape(bottomInset: 28)),
            ("landscape, controls up", landscape(bottomInset: 124))
        ] {
            let margins = geometry.margins
            let framePx = geometry.renderFrame.height * scale
            let videoAreaPx = framePx - CGFloat(margins.top) - CGFloat(margins.bottom)
            XCTAssertEqual(
                videoAreaPx, geometry.video.height * scale, accuracy: 1.5,
                "\(name): libass' video area should equal the real picture height"
            )
        }
    }

    // MARK: - Horizontal

    /// Pillarboxing is the horizontal counterpart and stays positive; the
    /// picture is genuinely narrower than the frame.
    func test_landscape_sideMarginsDescribeThePillarbox() {
        let margins = landscape(bottomInset: 28).margins
        XCTAssertEqual(margins.left, Int32((79.6 * 3).rounded()))
        XCTAssertEqual(margins.right, Int32(((874 - 794.4) * 3).rounded()))
    }

    func test_portrait_noSideMargins() {
        let margins = portrait(bottomInset: 28).margins
        XCTAssertEqual(margins.left, 0)
        XCTAssertEqual(margins.right, 0)
    }
}
