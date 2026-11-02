import SwiftUI
import XCTest
@testable import Dionysus

/// When Profile shows its sidebar-plus-detail split, checked against window
/// sizes measured on each device class.
final class SettingsLayoutTests: XCTestCase {
    private func usesSplit(
        _ horizontal: UserInterfaceSizeClass,
        _ vertical: UserInterfaceSizeClass,
        width: CGFloat
    ) -> Bool {
        SettingsLayout.usesSplitLayout(horizontalSizeClass: horizontal, verticalSizeClass: vertical, width: width)
    }

    func test_iPadsSplitEitherWayUp() {
        // iPad mini, the smallest iPad, then iPad Pro 13-inch.
        XCTAssertTrue(usesSplit(.regular, .regular, width: 744))
        XCTAssertTrue(usesSplit(.regular, .regular, width: 1133))
        XCTAssertTrue(usesSplit(.regular, .regular, width: 1032))
        XCTAssertTrue(usesSplit(.regular, .regular, width: 1376))
    }

    /// Held wide, the inner display splits; held tall (open, or propped in
    /// tabletop) it's regular both ways but too narrow to tile, and gets the
    /// one list.
    func test_foldableInnerDisplaySplitsOnlyHeldWide() {
        XCTAssertTrue(usesSplit(.regular, .regular, width: 951))
        XCTAssertFalse(usesSplit(.regular, .regular, width: 669))
    }

    func test_phonesNeverSplit() {
        // iPhone 17 portrait, a Pro Max in landscape, the foldable's outer
        // display.
        XCTAssertFalse(usesSplit(.compact, .regular, width: 402))
        XCTAssertFalse(usesSplit(.regular, .compact, width: 956))
        XCTAssertFalse(usesSplit(.compact, .regular, width: 466))
    }

    /// Before the first measurement the width reads 0: the one list.
    func test_unmeasuredWidthDoesNotSplit() {
        XCTAssertFalse(usesSplit(.regular, .regular, width: 0))
    }
}
