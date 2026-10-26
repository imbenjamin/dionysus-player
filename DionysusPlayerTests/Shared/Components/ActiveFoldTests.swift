import CoreGraphics
import XCTest
@testable import Dionysus

/// The fold geometry, from the reserved-region frames measured on the iPhone
/// Duo simulator (iOS 27.1): a 40pt band centred on the inner screen's middle,
/// at x 455–495 held wide (book) and y 455–495 held tall (tabletop).
final class ActiveFoldTests: XCTestCase {
    private let heldWide = CGSize(width: 951, height: 669)
    private let heldTall = CGSize(width: 669, height: 951)

    // MARK: ActiveFold

    func test_init_noFrameMeansNoFold() {
        XCTAssertNil(ActiveFold(frame: nil, in: heldWide))
    }

    func test_init_aTallBandIsABookFold() {
        let fold = ActiveFold(frame: CGRect(x: 455, y: 0, width: 40, height: 669), in: heldWide)
        XCTAssertEqual(fold, .vertical(leading: 455, trailing: 495))
    }

    func test_init_aWideBandIsATabletopFold() {
        let fold = ActiveFold(frame: CGRect(x: 0, y: 455, width: 669, height: 40), in: heldTall)
        XCTAssertEqual(fold, .horizontal(top: 455, bottom: 495))
    }

    /// Measured: a detail page reads the fold at x 455.667 and, without
    /// rounding, chased its own sub-point moves into a layout loop.
    func test_init_roundsToWholePoints() {
        let fold = ActiveFold(frame: CGRect(x: 455.667, y: -82, width: 40, height: 669), in: CGSize(width: 867.3, height: 553))
        XCTAssertEqual(fold, .vertical(leading: 456, trailing: 496))
    }

    /// A view that doesn't reach the fold (one half of Split View, say) has
    /// nothing to avoid.
    func test_init_aBandOutsideTheViewIsIgnored() {
        XCTAssertNil(ActiveFold(frame: CGRect(x: 455, y: 0, width: 40, height: 669), in: CGSize(width: 400, height: 669)))
    }

    // MARK: Player

    func test_player_flatKeepsTheFullScreenLayout() {
        let layout = PlayerFoldLayout(fold: nil)
        XCTAssertNil(layout.videoHeight)
        XCTAssertEqual(layout.controlsTopInset, 0)
        XCTAssertEqual(layout.controlsLeadingInset, 0)
    }

    /// Tabletop: the picture above the fold, the controls below it.
    func test_player_tabletopPutsVideoAboveAndControlsBelow() {
        let layout = PlayerFoldLayout(fold: .horizontal(top: 455, bottom: 495))
        XCTAssertEqual(layout.videoHeight, 455)
        XCTAssertEqual(layout.controlsTopInset, 495)
        XCTAssertEqual(layout.controlsLeadingInset, 0)
    }

    /// Book: the picture keeps the whole screen, the controls take the
    /// trailing page.
    func test_player_bookMovesControlsToTheTrailingPage() {
        let layout = PlayerFoldLayout(fold: .vertical(leading: 455, trailing: 495))
        XCTAssertNil(layout.videoHeight)
        XCTAssertEqual(layout.controlsTopInset, 0)
        XCTAssertEqual(layout.controlsLeadingInset, 495)
    }

    // MARK: Detail page

    /// Book: the poster fills the leading page up to the fold, the content
    /// starts past it.
    func test_detailSpread_bookSplitsAtTheFold() {
        let spread = DetailBookSpreadLayout(fold: .vertical(leading: 455, trailing: 495))
        XCTAssertEqual(spread?.posterWidth, 455)
        XCTAssertEqual(spread?.contentLeadingInset, 495)
    }

    func test_detailSpread_flatHasNoSpread() {
        XCTAssertNil(DetailBookSpreadLayout(fold: nil))
    }

    /// Tabletop's fold runs across the page, which scrolls through it; the page
    /// keeps its hero.
    func test_detailSpread_tabletopHasNoSpread() {
        XCTAssertNil(DetailBookSpreadLayout(fold: .horizontal(top: 455, bottom: 495)))
    }

    /// A poster names the title itself, so it shows without a logo.
    func test_detailSpread_aPosterShowsAlone() {
        let poster = URL(string: "https://example.com/poster")!
        let backdrop = URL(string: "https://example.com/backdrop")!
        XCTAssertEqual(DetailBookSpreadLayout.Artwork(posterURL: poster, backdropURL: backdrop), .poster(poster))
    }

    /// Without one, the backdrop stands in, with the logo over it.
    func test_detailSpread_withoutAPosterTheBackdropCarriesTheLogo() {
        let backdrop = URL(string: "https://example.com/backdrop")!
        XCTAssertEqual(DetailBookSpreadLayout.Artwork(posterURL: nil, backdropURL: backdrop), .backdropWithLogo(backdrop))
    }
}
