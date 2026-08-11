import XCTest
@testable import Dionysus

/// `DeviceTiltObserver` is mostly a thin `CMMotionManager` wrapper — real
/// sensor I/O, not something to unit test (same reasoning as
/// `DeviceIdentityTests`' doc comment for `UIDevice`/`UserDefaults`). Its
/// `smoothed(current:sample:factor:)` low-pass filter and
/// `uprightRelativeY(_:)` remap are pulled out as pure functions
/// specifically so these two pieces of actual logic have something to pin
/// down.
@MainActor
final class DeviceTiltObserverTests: XCTestCase {
    func test_smoothed_movesPartwayTowardTheSampleNotAllTheWay() {
        let result = DeviceTiltObserver.smoothed(current: 0, sample: 1, factor: 0.15)
        XCTAssertEqual(result, 0.15, accuracy: 0.0001)
    }

    func test_smoothed_repeatedApplicationConvergesTowardTheSample() {
        var value = 0.0
        for _ in 0..<200 {
            value = DeviceTiltObserver.smoothed(current: value, sample: 1, factor: 0.15)
        }
        XCTAssertEqual(value, 1, accuracy: 0.001)
    }

    func test_smoothed_zeroFactorNeverMoves() {
        XCTAssertEqual(DeviceTiltObserver.smoothed(current: 0.4, sample: 1, factor: 0), 0.4)
    }

    func test_smoothed_factorOneJumpsStraightToTheSample() {
        XCTAssertEqual(DeviceTiltObserver.smoothed(current: 0.4, sample: 1, factor: 1), 1)
    }

    func test_smoothed_negativeDirectionWorksTheSameWay() {
        let result = DeviceTiltObserver.smoothed(current: 0, sample: -1, factor: 0.15)
        XCTAssertEqual(result, -0.15, accuracy: 0.0001)
    }

    // MARK: uprightRelativeY

    func test_uprightRelativeY_heldUprightReadsAsCentered() {
        // -1 is what `CMDeviceMotion.gravity.y` reads when the phone is
        // held perfectly upright (top pointing at the sky) — see this
        // type's doc comment.
        XCTAssertEqual(DeviceTiltObserver.uprightRelativeY(-1), 0)
    }

    func test_uprightRelativeY_lyingFlatReadsAsFullyTiltedAwayFromUpright() {
        // 0 is what `gravity.y` reads lying flat, screen up.
        XCTAssertEqual(DeviceTiltObserver.uprightRelativeY(0), 1)
    }

    func test_uprightRelativeY_reclinedPartwayReadsPartwayBetween() {
        // A ~45° recline reads roughly -0.7 on gravity.y.
        XCTAssertEqual(DeviceTiltObserver.uprightRelativeY(-0.7), 0.3, accuracy: 0.0001)
    }

    func test_uprightRelativeY_clampsPastFlatRatherThanExceedingOne() {
        XCTAssertEqual(DeviceTiltObserver.uprightRelativeY(1), 1)
    }

    func test_uprightRelativeY_clampsPastUprightRatherThanGoingBelowNegativeOne() {
        XCTAssertEqual(DeviceTiltObserver.uprightRelativeY(-2), -1)
    }

    // MARK: freshly-constructed state

    func test_freshObserver_startsAtZero() {
        let observer = DeviceTiltObserver()
        XCTAssertEqual(observer.x, 0)
        XCTAssertEqual(observer.y, 0)
    }

    func test_freshObserver_isNotApplyingAChange() {
        let observer = DeviceTiltObserver()
        XCTAssertFalse(observer.isApplyingChange)
    }

    // MARK: start()/stop() guard clauses
    // No physical motion sensor in the Simulator (`isAvailable == false`),
    // so these exercise the guard-clause early return rather than a real
    // CoreMotion round-trip — same "not unit-testable" reasoning as this
    // file's own doc comment. Worth pinning down regardless: `start()`/
    // `stop()` must resolve (not hang) and leave `isApplyingChange` false
    // when there's nothing to actually do.

    func test_start_noOpWhenMotionUnavailable_leavesIsApplyingChangeFalse() async {
        let observer = DeviceTiltObserver()
        await observer.start()
        XCTAssertFalse(observer.isApplyingChange)
    }

    func test_stop_noOpWhenNeverStarted_leavesIsApplyingChangeFalse() async {
        let observer = DeviceTiltObserver()
        await observer.stop()
        XCTAssertFalse(observer.isApplyingChange)
    }

    func test_warmUp_noOpWhenMotionUnavailable_leavesIsApplyingChangeFalse() async {
        let observer = DeviceTiltObserver()
        await observer.warmUp()
        XCTAssertFalse(observer.isApplyingChange)
    }

    // MARK: acquire()/release()
    // Same "not unit-testable" ceiling as `start()`/`stop()` above applies
    // here too — no physical sensor in the Simulator to observe actually
    // starting/stopping, and the reference count/grace-period bookkeeping
    // that avoids the push-under race (see `release()`'s own doc comment)
    // is `private`, not something a test can inspect directly. What's worth
    // pinning down regardless: multiple `acquire()`/`release()` calls,
    // balanced or not, must resolve rather than hang or crash — the actual
    // race this pair fixes was found and confirmed live on a real device,
    // per `release()`'s doc comment, not something reproducible here.

    func test_acquireThenRelease_resolvesWithoutHanging() async {
        let observer = DeviceTiltObserver()
        await observer.acquire()
        await observer.release()
        XCTAssertFalse(observer.isApplyingChange)
    }

    func test_multipleAcquiresThenMatchingReleases_resolvesWithoutHanging() async {
        let observer = DeviceTiltObserver()
        await observer.acquire()
        await observer.acquire()
        await observer.release()
        await observer.release()
        XCTAssertFalse(observer.isApplyingChange)
    }

    func test_releaseWithoutAnyPriorAcquire_doesNotUnderflowOrCrash() async {
        let observer = DeviceTiltObserver()
        await observer.release()
        XCTAssertFalse(observer.isApplyingChange)
    }

    /// The exact scenario `release()`'s grace period exists for: a release
    /// immediately followed by a re-acquire (standing in for navigating
    /// straight from one detail page to another) shouldn't hang or crash
    /// either.
    func test_releaseImmediatelyFollowedByReacquire_resolvesWithoutHanging() async {
        let observer = DeviceTiltObserver()
        await observer.acquire()
        async let release: Void = observer.release()
        await observer.acquire()
        await release
        XCTAssertFalse(observer.isApplyingChange)
    }
}
