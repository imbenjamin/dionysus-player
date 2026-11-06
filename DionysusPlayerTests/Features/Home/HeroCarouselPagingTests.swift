import XCTest
@testable import Dionysus

/// The hero carousel's countdown and looped paging. No journey sees the
/// carousel move (the UI-test harness holds it still), so these are what
/// guard the auto-advance.
final class HeroCarouselPagingTests: XCTestCase {
    private let three = HeroCarouselPaging(count: 3)

    // MARK: - The countdown

    func test_advancesAfterFiveUnpausedSeconds_thenCountsAgainFromZero() {
        var idle = 0
        var advances: [Bool] = []
        for _ in 0..<10 {
            let tick = three.tick(idleSeconds: idle, isPaused: false)
            idle = tick.idleSeconds
            advances.append(tick.advances)
        }
        XCTAssertEqual(advances, [false, false, false, false, true, false, false, false, false, true])
        XCTAssertEqual(idle, 0)
    }

    /// A finger on the carousel, Home covered or manual mode pauses the
    /// countdown where it was, rather than restarting it.
    func test_paused_holdsTheCountWhereItWas() {
        let tick = three.tick(idleSeconds: 3, isPaused: true)
        XCTAssertEqual(tick.idleSeconds, 3)
        XCTAssertFalse(tick.advances)
        let resumed = three.tick(idleSeconds: tick.idleSeconds, isPaused: false)
        XCTAssertEqual(resumed.idleSeconds, 4, "Picks up from where it paused")
        XCTAssertTrue(three.tick(idleSeconds: resumed.idleSeconds, isPaused: false).advances)
    }

    func test_oneItemOrNone_neverCountsOrAdvances() {
        for count in [0, 1] {
            let paging = HeroCarouselPaging(count: count)
            let tick = paging.tick(idleSeconds: 4, isPaused: false)
            XCTAssertEqual(tick.idleSeconds, 4)
            XCTAssertFalse(tick.advances)
            XCTAssertNil(paging.position(from: 0, movingBy: 1))
        }
    }

    // MARK: - Looped positions

    /// Three items loop as [C] A B C [A]: five pages, the first real one at 1.
    func test_threeItems_padOnePageEachSide() {
        XCTAssertEqual(three.loopedCount, 5)
        XCTAssertEqual(three.firstPagePosition, 1)
        XCTAssertEqual(HeroCarouselPaging(count: 1).loopedCount, 1)
        XCTAssertEqual(HeroCarouselPaging(count: 1).firstPagePosition, 0)
    }

    func test_index_readsPaddingAsTheItemItCopies() {
        XCTAssertEqual((0..<5).map { three.index(atPosition: $0) }, [2, 0, 1, 2, 0])
        XCTAssertEqual(three.index(atPosition: nil), 0, "Before the first layout pass")
    }

    func test_advance_movesOnePage_andOffTheEndOntoTheCopy() {
        XCTAssertEqual(three.position(from: 1, movingBy: 1), 2)
        XCTAssertEqual(three.position(from: 3, movingBy: 1), 4, "Onto the copy of the first, then snapped")
        XCTAssertEqual(three.position(from: 1, movingBy: -1), 0, "Onto the copy of the last")
        XCTAssertEqual(three.position(from: nil, movingBy: 1), 2, "From the first page before layout")
    }

    /// A second Previous/Next tap before the snap starts from the real page
    /// the copy shows, so it never walks off the looped list.
    func test_advanceFromACopy_startsFromTheRealPage() {
        XCTAssertEqual(three.position(from: 4, movingBy: 1), 2)
        XCTAssertEqual(three.position(from: 0, movingBy: -1), 2)
        for position in 0..<three.loopedCount {
            for delta in [-1, 1] {
                let next = three.position(from: position, movingBy: delta)!
                XCTAssertTrue((0..<three.loopedCount).contains(next), "\(position) + \(delta) = \(next)")
            }
        }
    }

    func test_snap_onlyFromACopy_toTheRealPageItShows() {
        XCTAssertEqual(three.snapTarget(from: 0), 3)
        XCTAssertEqual(three.snapTarget(from: 4), 1)
        for real in 1...3 { XCTAssertNil(three.snapTarget(from: real)) }
        XCTAssertNil(HeroCarouselPaging(count: 1).snapTarget(from: 0))
    }
}
