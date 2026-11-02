import XCTest
@testable import Dionysus

final class TVPlayerFocusIDTests: XCTestCase {
    func test_describesTheScrubberAnIconOrNothing() {
        var state = TVPlayerInputState()
        let context = TVPlayerContext(duration: 600, chapterStarts: [0, 300])
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "scrubber")
        state.transportFocus = .icon(.chapters)
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "icon.chapters")
        state.chrome = .hidden
        state.transportFocus = .scrubber
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "none")
    }
}
