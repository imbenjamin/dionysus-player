import SwiftUI
import XCTest
@testable import Dionysus

/// A destructive row draws its own platter from its focus: a red title on the
/// resting glass, white on a red platter in focus. Following focus with the
/// system's destructive role showed a grey platter for a frame as focus left
/// (Benjamin, 2026-10-13).
final class TVSettingsRowTests: XCTestCase {
    /// The system row's platter, measured on tvOS 26.5, so the red rows line
    /// up with their neighbours. The look itself can only be checked frame by
    /// frame (`DionysusTV/CLAUDE.md`); this guards the measured numbers.
    func test_destructiveRow_matchesTheSystemRowsGeometry() {
        XCTAssertEqual(TVDestructiveRowStyle.height, 66)
        XCTAssertEqual(TVDestructiveRowStyle.titleInset, 30)
        XCTAssertEqual(TVDestructiveRowStyle.focusOutset, CGSize(width: 4, height: 3.5))
    }
}
