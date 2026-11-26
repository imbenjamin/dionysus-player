import XCTest
@testable import Dionysus

/// Putting the changed-certificate warning on screen (#466), with UIKit and
/// the clock replaced: each test scripts what a try finds.
@MainActor
final class CertificateWarningPresentationAttemptsTests: XCTestCase {
    /// A scripted world: what each read returns, and what was done.
    private final class World {
        var playerUp = false
        var active = true
        var wanted = true
        var appears = false
        var presentedStays = false
        var dismissWorks = true
        var presented = false
        var events: [String] = []
        var sleeps: [Duration] = []
        /// Run on each `present()`, to change the world mid-try.
        var onPresent: (World) -> Void = { _ in }
    }

    private func attempts(_ world: World, tries: Int = 3) -> CertificateWarningPresentationAttempts {
        var attempts = CertificateWarningPresentationAttempts(
            isPlayerUp: { world.playerUp },
            isActive: { world.active },
            isWanted: { world.wanted },
            hasAppeared: { world.presented && world.appears },
            isPresented: { world.presented && world.presentedStays },
            dismissOthers: {
                world.events.append("dismiss")
                return world.dismissWorks
            },
            present: {
                world.events.append("present")
                world.presented = true
                world.onPresent(world)
            },
            withdraw: {
                world.events.append("withdraw")
                world.presented = false
            }
        )
        attempts.tries = tries
        attempts.sleep = { world.sleeps.append($0) }
        return attempts
    }

    func testAPageThatAppearsIsShown() async {
        let world = World()
        world.appears = true
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .shown)
        XCTAssertEqual(world.events, ["dismiss", "present"])
    }

    /// N2: presented but slow to appear is left alone, never torn down.
    func testAPagePresentedButNotYetAppearedIsLeftUp() async {
        let world = World()
        world.presentedStays = true
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .shown)
        XCTAssertFalse(world.events.contains("withdraw"))
    }

    /// A refused presentation (nothing presented) is withdrawn and tried again.
    func testARefusedPresentationIsTriedAgain() async {
        let world = World()
        var presents = 0
        world.onPresent = { world in
            presents += 1
            if presents == 2 { world.appears = true }
        }
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .shown)
        XCTAssertEqual(world.events, ["dismiss", "present", "withdraw", "dismiss", "present"])
    }

    /// I1: nothing can be shown in any try, so the caller ends it as Not Now.
    func testEveryTryRefusedGivesUp() async {
        let world = World()
        let outcome = await attempts(world, tries: 3).run()
        XCTAssertEqual(outcome, .gaveUp)
        XCTAssertEqual(world.events.filter { $0 == "present" }.count, 3)
        XCTAssertFalse(world.presented, "Nothing is left presented")
    }

    /// N1: the player is checked before any dismissal, so its chain is never closed.
    func testAPlayerUpDismissesNothing() async {
        let world = World()
        world.playerUp = true
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .playerUp)
        XCTAssertEqual(world.events, [])
    }

    /// N1: a player that comes up during a try stops the next one before it
    /// dismisses anything, read live rather than as it was when trying began.
    func testAPlayerComingUpMidTryStopsBeforeTheNextDismissal() async {
        let world = World()
        world.onPresent = { world in world.playerUp = true }
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .playerUp)
        XCTAssertEqual(world.events, ["dismiss", "present", "withdraw"])
    }

    /// A chain that wouldn't close (a transition running, a protected
    /// controller) isn't presented over; the try is spent waiting.
    func testAChainThatWontCloseIsNotPresentedOver() async {
        let world = World()
        world.dismissWorks = false
        let outcome = await attempts(world, tries: 2).run()
        XCTAssertEqual(outcome, .gaveUp)
        XCTAssertEqual(world.events, ["dismiss", "dismiss"])
    }

    /// M8: a refused dismissal (a transition still running) waits as long as
    /// a refused presentation, not just the short pause, so a long
    /// transition doesn't run the tries out in a second and a half.
    func testARefusedDismissalWaitsAsLongAsARefusedPresentation() async {
        let world = World()
        world.dismissWorks = false
        let subject = attempts(world, tries: 2)
        _ = await subject.run()
        XCTAssertEqual(world.sleeps, [subject.settle, subject.settle])
    }

    /// M10: stopped while inactive, a run once the app is active again
    /// shows the page (the presenter starts one on the same signal).
    func testStoppedInactiveThenActiveAgainResumes() async {
        let world = World()
        world.active = false
        world.appears = true
        let subject = attempts(world)
        let first = await subject.run()
        XCTAssertEqual(first, .inactive)
        XCTAssertEqual(world.events, [], "Nothing tried while inactive")

        world.active = true
        let second = await subject.run()
        XCTAssertEqual(second, .shown)
        XCTAssertEqual(world.events, ["dismiss", "present"])
    }

    /// Away from the foreground nothing is tried, and nothing gives up.
    func testAnInactiveAppWaits() async {
        let world = World()
        world.active = false
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .inactive)
        XCTAssertEqual(world.events, [])
    }

    /// Answered or cleared meanwhile: stops, never gives up on its behalf.
    func testAWarningNoLongerWantedStops() async {
        let world = World()
        world.onPresent = { world in world.wanted = false }
        let outcome = await attempts(world).run()
        XCTAssertEqual(outcome, .notWanted)
    }
}
