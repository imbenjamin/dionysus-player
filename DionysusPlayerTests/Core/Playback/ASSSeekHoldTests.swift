import XCTest
@testable import Dionysus

/// The hold that keeps libass off a transcode's playhead while AetherEngine
/// says `sourceTime` is only a guess — from a time jump until a line has
/// re-measured the lead.
///
/// Every time here is item time, the axis the timeout counts playback on.
final class ASSSeekHoldTests: XCTestCase {

    /// Nothing is painted while the engine hasn't re-measured.
    func test_whileTheEngineIsUnsure_holdsBack() {
        var hold = ASSSeekHold(followsPicture: true)
        play(&hold, from: 1470, to: 1472)

        hold.observeFollowsPicture(false)  // the scrub
        play(&hold, from: 1480, to: 1482)

        XCTAssertNil(hold.renderTime(for: 1480))
    }

    /// Once the engine has re-measured, libass renders at `sourceTime`
    /// exactly — nothing is subtracted here. Subtracting as well was the
    /// double correction a pre-7.15.2 calibrator would apply.
    func test_onceTheEngineFollowsThePicture_rendersAtSourceTimeUnchanged() throws {
        var hold = ASSSeekHold(followsPicture: false)
        play(&hold, from: 1480, to: 1482)

        hold.observeFollowsPicture(true)

        XCTAssertEqual(try XCTUnwrap(hold.renderTime(for: 1480.9)), 1480.9)
    }

    /// Created while the engine is already sure — a styled track picked
    /// mid-film, long after the last seek — renders straight away.
    func test_createdWhileTheEngineFollowsThePicture_rendersImmediately() {
        let hold = ASSSeekHold(followsPicture: true)
        XCTAssertEqual(hold.renderTime(for: 42), 42)
    }

    /// Something libass draws that the rendition doesn't carry can't hold the
    /// overlay back forever.
    func test_givesUpAfterTheTimeout() {
        var hold = ASSSeekHold(followsPicture: false)

        play(&hold, from: 100, to: 100 + ASSSeekHold.holdTimeout - 0.2)
        XCTAssertNil(hold.renderTime(for: 104))

        play(&hold, from: 100 + ASSSeekHold.holdTimeout - 0.2, to: 100 + ASSSeekHold.holdTimeout + 0.2)
        XCTAssertNotNil(hold.renderTime(for: 105))
    }

    /// The timeout counts playback, so a paused player stays held however
    /// long it sits there.
    func test_aPause_doesNotCountTowardsTheTimeout() {
        var hold = ASSSeekHold(followsPicture: false)
        play(&hold, from: 100, to: 102)

        for _ in 0..<100 { hold.observeItemTime(102) }

        XCTAssertNil(hold.renderTime(for: 102))
    }

    /// A seek is one large item-time step, which is not playback — even when
    /// the engine's `false` for it arrives after the tick that lands.
    func test_aForwardSeek_doesNotCountTowardsTheTimeout() {
        var hold = ASSSeekHold(followsPicture: false)
        play(&hold, from: 100, to: 101)

        hold.observeItemTime(2000)

        XCTAssertNil(hold.renderTime(for: 2000))
    }

    /// A repeated `false` is another time jump, so it restarts the wait: a
    /// second scrub moments before the first one would have timed out still
    /// gets its own full hold.
    func test_aRepeatedFalse_restartsTheTimeout() {
        var hold = ASSSeekHold(followsPicture: false)
        play(&hold, from: 100, to: 104.5)

        hold.observeFollowsPicture(false)
        play(&hold, from: 3000, to: 3002)

        XCTAssertNil(hold.renderTime(for: 3001))
    }

    /// A jump after the engine had re-measured holds again.
    func test_aJumpAfterReleasing_holdsAgain() {
        var hold = ASSSeekHold(followsPicture: false)
        hold.observeFollowsPicture(true)
        play(&hold, from: 100, to: 110)

        hold.observeFollowsPicture(false)

        XCTAssertNil(hold.renderTime(for: 50))
    }

    // MARK: - Helpers

    /// Ticks item time forward at the engine's 100ms cadence.
    private func play(_ hold: inout ASSSeekHold, from start: TimeInterval, to end: TimeInterval) {
        var time = start
        while time <= end + 0.0001 {
            hold.observeItemTime(time)
            time += 0.1
        }
    }
}
