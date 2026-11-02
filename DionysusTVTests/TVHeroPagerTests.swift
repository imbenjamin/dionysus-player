import XCTest
@testable import Dionysus

final class TVHeroPagerTests: XCTestCase {
    func test_tick_advances_andWrapsToTheStart() {
        var pager = TVHeroPager(count: 3)
        pager.tick()
        XCTAssertEqual(pager.index, 1)
        pager.tick()
        pager.tick()
        XCTAssertEqual(pager.index, 0)
    }

    /// Right on More Info wraps to the first item, as the timer does
    /// (Benjamin, 2026-10-04). There is no paging back: Left on Play always
    /// opens the rail.
    func test_forwardByHand_wrapsToTheStart() {
        var pager = TVHeroPager(count: 2)
        XCTAssertTrue(pager.canGoForward)
        pager.forward()
        XCTAssertEqual(pager.index, 1)
        XCTAssertTrue(pager.canGoForward)
        pager.forward()
        XCTAssertEqual(pager.index, 0)
    }

    func test_forwardByHand_withOneItem_goesNowhere() {
        var pager = TVHeroPager(count: 1)
        XCTAssertFalse(pager.canGoForward)
        pager.forward()
        XCTAssertEqual(pager.index, 0)
    }

    /// Long enough to read the overview (Benjamin, 2026-10-04).
    func test_theTimerWaitsTenSeconds() {
        XCTAssertEqual(TVHeroPager.interval, .seconds(10))
    }

    /// The pip's fill is animated over the same interval the timer waits.
    func test_thePipFillsOverTheTimersInterval() {
        XCTAssertEqual(TVHeroPager.intervalSeconds, 10, accuracy: 0.001)
    }

    func test_aPressByHand_stopsTheTimerForThisVisit_andLeavingStartsItAgain() {
        var pager = TVHeroPager(count: 3)
        pager.forward()
        XCTAssertTrue(pager.stoppedByHand)
        pager.heroLostFocus()
        XCTAssertFalse(pager.stoppedByHand)
    }

    func test_timerRuns_onlyWhenEverythingAllowsIt() {
        func runs(count: Int = 3, auto: Bool = true, reduce: Bool = false, frozen: Bool = false, focus: Bool = true, onShow: Bool = true, stopped: Bool = false, voiceOver: Bool = false) -> Bool {
            TVHeroPager.timerRuns(count: count, autoCarousel: auto, reduceMotion: reduce, motionFrozen: frozen, voiceOver: voiceOver, heroHasFocus: focus, isOnShow: onShow, stoppedByHand: stopped)
        }
        XCTAssertTrue(runs())
        XCTAssertFalse(runs(count: 1), "One item has nowhere to go")
        XCTAssertFalse(runs(count: 0))
        XCTAssertFalse(runs(auto: false), "Auto Carousel is off")
        XCTAssertFalse(runs(reduce: true))
        XCTAssertFalse(runs(frozen: true), "The UI-test harness freezes ambient motion")
        XCTAssertFalse(runs(focus: false), "Only while the hero has focus")
        XCTAssertFalse(runs(onShow: false), "A hidden page runs no timer")
        XCTAssertFalse(runs(stopped: true))
        XCTAssertFalse(runs(voiceOver: true), "VoiceOver needs to read one item fully, as on iOS")
    }

    /// A refresh can return fewer hero items than the index points at.
    func test_setCount_clampsTheIndex() {
        var pager = TVHeroPager(count: 5)
        pager.tick(); pager.tick(); pager.tick()
        pager.setCount(2)
        XCTAssertEqual(pager.index, 1)
        pager.setCount(0)
        XCTAssertEqual(pager.index, 0)
        pager.tick()
        XCTAssertEqual(pager.index, 0, "Nothing to advance through")
    }
}
