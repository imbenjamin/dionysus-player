import SwiftUI
import XCTest
@testable import Dionysus

/// Which tab bar placements let Home's hero choose the tab bar's tint. The
/// placements are the ones measured on iOS 27: `.topBar` on an iPad,
/// `.bottomBar` on an iPhone Duo's inner display, held tall or wide.
final class TabBarTintTests: XCTestCase {
    func test_isBarOverHero_iPadsFloatingBarIs() {
        XCTAssertTrue(TabBarTintModel.isBarOverHero(.topBar))
    }

    /// An iPhone's bar, and a Duo's: regular width on the inner display, but
    /// over the rails (2.35:1 held wide, about 2.9:1 in tabletop, audit
    /// 2026-10-26).
    func test_isBarOverHero_aBottomBarIsNot() {
        XCTAssertFalse(TabBarTintModel.isBarOverHero(.bottomBar))
    }

    func test_isBarOverHero_aSidebarIsNot() {
        XCTAssertFalse(TabBarTintModel.isBarOverHero(.sidebar))
    }

    func test_isBarOverHero_unknownIsNot() {
        XCTAssertFalse(TabBarTintModel.isBarOverHero(nil))
    }
}
