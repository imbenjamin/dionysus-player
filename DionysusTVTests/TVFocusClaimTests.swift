import XCTest
@testable import Dionysus

/// A page's focus claim sets focus again until it holds, but stops at the
/// first direction press (#311: on CI's slower runner, Down from Home's Play
/// was pulled back to Play, and the next Select played instead of opening
/// the tile).
@MainActor
final class TVFocusClaimTests: XCTestCase {
    /// Focus as tvOS leaves it, the sets the claim makes, and the presses
    /// the person makes, scripted per wait.
    @MainActor
    private final class Remote {
        var focused: String?
        var sets: [String] = []
        var presses = 0
        /// Run at each wait, before the claim looks again.
        var onWait: [Int: (Remote) -> Void] = [:]
        private var waits = 0

        func reclaim(_ target: String, attempts: Int = 10) async {
            await TVFocusClaim.reclaim(
                target,
                attempts: attempts,
                current: { self.focused },
                // A set doesn't land by itself here: tvOS's own pick wins
                // until the script says otherwise.
                set: { self.sets.append($0) },
                pressesSinceClaim: { self.presses },
                sleep: { _ in
                    self.waits += 1
                    self.onWait[self.waits]?(self)
                }
            )
        }
    }

    func test_focusThatNeverLands_isSetAgainEachWait_upToTheLimit() async {
        let remote = Remote()
        remote.focused = "synopsis"
        await remote.reclaim("play", attempts: 10)
        XCTAssertEqual(remote.sets, Array(repeating: "play", count: 10))
    }

    func test_focusThatHolds_stopsTheClaim() async {
        let remote = Remote()
        remote.focused = "synopsis"
        remote.onWait[2] = { $0.focused = "play" }
        await remote.reclaim("play")
        XCTAssertEqual(remote.sets, ["play"], "Set once after the first wait, then it held")
    }

    /// #311: a press made before focus has landed ends the claim, so the
    /// press isn't pulled back.
    func test_aPressBeforeFocusLands_endsTheClaim_withoutSettingItAgain() async {
        let remote = Remote()
        remote.focused = "synopsis"
        remote.onWait[3] = { remote in
            remote.presses += 1
            remote.focused = "tile"
        }
        await remote.reclaim("play")
        XCTAssertEqual(remote.sets, ["play", "play"], "Set after the first two waits, none after the press")
        XCTAssertEqual(remote.focused, "tile", "Focus stays where the press took it")
    }

    func test_aPressAtTheFirstWait_setsNothing() async {
        let remote = Remote()
        remote.focused = "synopsis"
        remote.onWait[1] = { $0.presses += 1 }
        await remote.reclaim("play")
        XCTAssertTrue(remote.sets.isEmpty)
    }
}
