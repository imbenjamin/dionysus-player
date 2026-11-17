import XCTest
@testable import Dionysus

/// Profile's Night Mode page (`TVNightModePage`): where each level control
/// takes a level, as the player's Night tab does.
final class TVNightModePageTests: XCTestCase {
    func test_target_stepsFiveOrGoesToAnEnd() {
        XCTAssertEqual(TVNightLevelRow.target(of: .decrease, from: 100), 95)
        XCTAssertEqual(TVNightLevelRow.target(of: .increase, from: 95), 100)
        XCTAssertEqual(TVNightLevelRow.target(of: .min, from: 60), 0)
        XCTAssertEqual(TVNightLevelRow.target(of: .max, from: 60), 100)
    }

    /// At an end the step does nothing, which is when the tab dims it.
    func test_target_clampsAtTheEnds() {
        XCTAssertEqual(TVNightLevelRow.target(of: .increase, from: 100), 100)
        XCTAssertEqual(TVNightLevelRow.target(of: .decrease, from: 0), 0)
        for control in TVNightLevelControl.allCases {
            for percent in [0, 50, 100] {
                XCTAssertEqual(
                    TVNightLevelRow.target(of: control, from: percent) == percent,
                    TVPlayerInputModel.nightControlIsInert(control, percent: percent),
                    "\(control) at \(percent)"
                )
            }
        }
    }
}
