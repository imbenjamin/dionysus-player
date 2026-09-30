import UIKit
import XCTest
@testable import Dionysus

final class TVKeyboardCommandTests: XCTestCase {
    /// The system player's mapping, and what the Simulator's on-screen remote
    /// sends for its Play/Pause button.
    func test_spaceBar_isPlayPause() {
        XCTAssertEqual(TVKeyboardCommand(keyCode: .keyboardSpacebar), .playPause)
    }

    /// Arrows and Escape already arrive as remote presses too, so they are
    /// left to those handlers rather than acted on twice.
    func test_otherKeys_areNotCommands() {
        XCTAssertNil(TVKeyboardCommand(keyCode: .keyboardLeftArrow))
        XCTAssertNil(TVKeyboardCommand(keyCode: .keyboardEscape))
        XCTAssertNil(TVKeyboardCommand(keyCode: .keyboardA))
    }
}
