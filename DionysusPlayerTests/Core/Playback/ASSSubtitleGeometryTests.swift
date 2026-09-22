import CoreGraphics
import UIKit
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
            // Sensor housing at the top, home indicator at the bottom.
            safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
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
            // Rotated, iOS insets both sides for the sensor housing.
            safeArea: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62),
            bottomInset: bottomInset,
            scale: scale
        )
    }

    /// Landscape with the picture filling the screen — `.fill` zoom, or simply
    /// a 19.5:9 source. The picture's own corners are then underneath the
    /// device's, which is the case that was drawing off the physical display.
    private func landscapeFullBleed(bottomInset: CGFloat) -> ASSSubtitleRenderSession.Geometry {
        ASSSubtitleRenderSession.Geometry(
            frame: CGSize(width: 874, height: 402),
            video: CGRect(x: 0, y: 0, width: 874, height: 402),
            safeArea: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62),
            bottomInset: bottomInset,
            scale: scale
        )
    }

    // MARK: - Frame origin

    /// The drawable region starts at the picture's top edge, so there is no top
    /// margin for a top-aligned sign to be relocated into.
    func test_portrait_drawableStartsAtThePictureNotTheOverlay() {
        let geometry = portrait(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.minY, 323.94, accuracy: 0.01)
        XCTAssertEqual(geometry.margins.top, 0)
    }

    /// In landscape the picture already starts at the overlay's top and there
    /// is no top inset, so the drawable region does too.
    func test_landscape_drawableStartsAtThePicture() {
        let geometry = landscape(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.minY, 0)
        XCTAssertEqual(geometry.margins.top, 0)
    }

    // MARK: - Safe area

    /// The reported bug: with the picture filling the screen, a corner-aligned
    /// sign drew under the rounded corner and the sensor housing and was
    /// physically cut off — invisible in a screenshot, since the framebuffer
    /// has no corners.
    func test_landscapeFullBleed_drawableStaysInsideTheSafeArea() {
        let geometry = landscapeFullBleed(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.minX, 62)
        XCTAssertEqual(geometry.drawable.maxX, 874 - 62)
        // Negative: the drawable region is inside the picture horizontally.
        XCTAssertLessThan(geometry.margins.left, 0)
        XCTAssertLessThan(geometry.margins.right, 0)
    }

    /// Pillarboxed landscape is already clear of the housing — the bars are
    /// wider than the inset — so the picture's own edge wins and the horizontal
    /// margins come out at zero: the drawable region IS the picture across.
    func test_landscapePillarboxed_pictureEdgeWinsOverTheSafeArea() {
        let geometry = landscape(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.minX, 79.6, accuracy: 0.01)
        XCTAssertEqual(geometry.drawable.maxX, 794.4, accuracy: 0.01)
        XCTAssertEqual(geometry.margins.left, 0)
        XCTAssertEqual(geometry.margins.right, 0)
    }

    /// Portrait has no side insets, so the picture spans the full width.
    func test_portrait_noHorizontalInsetting() {
        let geometry = portrait(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.minX, 0)
        XCTAssertEqual(geometry.drawable.maxX, 402)
    }

    /// At rest the clearance is the home indicator's real height rather than
    /// the constant's approximation of it.
    func test_restingBottomClearsTheHomeIndicator() {
        let geometry = portrait(bottomInset: 28)
        XCTAssertEqual(geometry.drawable.maxY, 874 - 34, "safe-area bottom (34) should win over the 28pt resting inset")
    }

    /// With the controls up the chrome clearance is much larger, so it wins.
    func test_controlsUpBottomUsesTheChromeClearance() {
        let geometry = portrait(bottomInset: 132)
        XCTAssertEqual(geometry.drawable.maxY, 874 - 132)
    }

    // MARK: - Signed bottom margin

    /// Portrait has real empty space below the picture, so the margin is
    /// positive and regular dialogue has somewhere to be relocated to.
    func test_portrait_bottomMarginIsPositive() {
        let geometry = portrait(bottomInset: 132)
        // Drawable runs from the picture's top (323.94) to 874 - 132; the
        // picture ends at 550.07, leaving 191.93pt of bar.
        XCTAssertEqual(geometry.margins.bottom, Int32((191.93 * 3).rounded()))
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
            ("landscape, controls up", landscape(bottomInset: 124)),
            ("landscape full-bleed", landscapeFullBleed(bottomInset: 28))
        ] {
            let margins = geometry.margins
            let framePx = geometry.renderFrame.height * scale
            let videoAreaPx = framePx - CGFloat(margins.top) - CGFloat(margins.bottom)
            XCTAssertEqual(
                videoAreaPx, geometry.video.height * scale, accuracy: 1.5,
                "\(name): libass' video area should equal the real picture height"
            )
            let widthPx = geometry.renderFrame.width * scale
            XCTAssertEqual(
                widthPx - CGFloat(margins.left) - CGFloat(margins.right),
                geometry.video.width * scale, accuracy: 1.5,
                "\(name): and the real picture width"
            )
        }
    }

    // MARK: - Horizontal

    func test_portrait_noSideMargins() {
        let margins = portrait(bottomInset: 28).margins
        XCTAssertEqual(margins.left, 0)
        XCTAssertEqual(margins.right, 0)
    }
}
