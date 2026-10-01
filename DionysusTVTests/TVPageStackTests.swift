import XCTest
@testable import Dionysus

/// Only the topmost page draws its content (Benjamin, 2026-10-01): a page
/// under a library page, the player or a future details page is torn down,
/// since the app is image heavy. The shell is the bottom of the stack.
@MainActor
final class TVPageStackTests: XCTestCase {
    func test_emptyStack_leavesTheShellUncovered() {
        let stack = TVPageStack()
        XCTAssertFalse(stack.isShellCovered)
    }

    func test_aPage_coversTheShell_andIsItselfOnTop() {
        let stack = TVPageStack()
        let library = stack.push()
        XCTAssertTrue(stack.isShellCovered)
        XCTAssertFalse(stack.isCovered(library))
    }

    /// The player over a library page covers both.
    func test_aSecondPage_coversTheFirst() {
        let stack = TVPageStack()
        let library = stack.push()
        let player = stack.push()
        XCTAssertTrue(stack.isCovered(library))
        XCTAssertFalse(stack.isCovered(player))
    }

    func test_popping_uncoversWhatWasBelow() {
        let stack = TVPageStack()
        let library = stack.push()
        let player = stack.push()
        stack.pop(player)
        XCTAssertFalse(stack.isCovered(library))
        stack.pop(library)
        XCTAssertFalse(stack.isShellCovered)
    }

    /// Pages can go in any order (a cover's disappearance can land after the
    /// next page's appearance), so popping removes that page, not the top.
    func test_poppingAPageBelowTheTop_removesThatPage() {
        let stack = TVPageStack()
        let library = stack.push()
        let player = stack.push()
        stack.pop(library)
        XCTAssertFalse(stack.isCovered(player))
        XCTAssertTrue(stack.isShellCovered)
    }
}
