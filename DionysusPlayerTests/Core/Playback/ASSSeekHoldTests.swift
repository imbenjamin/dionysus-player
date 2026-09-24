import XCTest
@testable import Dionysus

/// The hold that keeps libass off a transcode's playhead between a seek and the
/// first line after it, while AetherEngine's `sourceTime` still carries the
/// previous seek's lead.
///
/// Every time here is item time, the axis both inputs arrive on.
final class ASSSeekHoldTests: XCTestCase {

    /// Nothing is painted between a seek and the first line after it: the
    /// engine hasn't re-measured yet.
    func test_afterASeek_holdsBackUntilALineStarts() {
        var hold = ASSSeekHold()
        playFromStart(&hold)

        hold.observeItemTime(1480)  // the scrub

        XCTAssertNil(hold.renderTime(for: 1478))
        play(&hold, from: 1480, to: 1482)
        XCTAssertNil(hold.renderTime(for: 1480))
    }

    /// Once a line starts, libass renders at `sourceTime` exactly — the engine
    /// has corrected it, so nothing is subtracted here. Subtracting as well was
    /// the double correction a pre-7.15.2 calibrator would apply.
    func test_afterALineStarts_rendersAtSourceTimeUnchanged() throws {
        var hold = ASSSeekHold()
        playFromStart(&hold)
        hold.observeItemTime(1480)
        play(&hold, from: 1480, to: 1482)
        hold.observeCues([""], at: 1482)  // the first delivery after a jump
        play(&hold, from: 1482, to: 1484.5)

        hold.observeCues(["Say \"cheese\" & smile."], at: 1484.7)

        XCTAssertEqual(try XCTUnwrap(hold.renderTime(for: 1483.5)), 1483.5)
    }

    /// A scene with no dialogue can't hold the overlay back forever.
    func test_afterASeek_givesUpWaiting() throws {
        var hold = ASSSeekHold()
        playFromStart(&hold)
        hold.observeItemTime(1480)

        play(&hold, from: 1480, to: 1480 + ASSSeekHold.holdTimeout)

        XCTAssertEqual(try XCTUnwrap(hold.renderTime(for: 1483)), 1483)
    }

    /// A line on screen when the playhead lands is re-delivered at the landing
    /// time. The engine measures nothing from it, so it must not lift the hold.
    func test_aLineCarriedOverTheSeek_doesNotRelease() {
        var hold = ASSSeekHold()
        playFromStart(&hold)

        hold.observeItemTime(1485)
        hold.observeCues(["Hello."], at: 1485.05)
        hold.observeCues(["Hello."], at: 1485.1)

        XCTAssertNil(hold.renderTime(for: 1485.1))
    }

    /// The engine ignores the first delivery after AVPlayer reports a time jump,
    /// even one that isn't a carry-over, so that one can't release either:
    /// `sourceTime` would still be on the old lead.
    func test_theFirstDeliveryAfterASeek_doesNotRelease() {
        var hold = ASSSeekHold()
        playFromStart(&hold)
        hold.observeItemTime(1480)
        play(&hold, from: 1480, to: 1482)

        hold.observeCues(["A line."], at: 1482)

        XCTAssertNil(hold.renderTime(for: 1481))
        hold.observeCues(["A line.", "Another line."], at: 1483)
        XCTAssertNotNil(hold.renderTime(for: 1482))
    }

    /// AVPlayer re-delivers every line still showing whenever another starts.
    /// A delivery that only repeats what is on screen, or only ends a line,
    /// starts nothing.
    func test_onlyALineThatJustStarted_releases() {
        var hold = ASSSeekHold()
        playFromStart(&hold)
        hold.observeItemTime(1480)
        play(&hold, from: 1480, to: 1481)
        hold.observeCues([], at: 1481)  // consumes the post-jump skip

        hold.observeCues([], at: 1481.5)
        XCTAssertNil(hold.renderTime(for: 1481.5))

        hold.observeCues(["A line."], at: 1482)
        XCTAssertNotNil(hold.renderTime(for: 1482))
    }

    /// A line delivered before the tick that would reveal the seek is checked
    /// against the previous tick first, so it still counts as the seek's
    /// carry-over rather than a start.
    func test_aCueArrivingBeforeTheSeekTick_stillCountsAsACarryOver() {
        var hold = ASSSeekHold()
        playFromStart(&hold)

        hold.observeCues(["Hello."], at: 1485.1)

        XCTAssertNil(hold.renderTime(for: 1485.1))
    }

    /// The engine lowering `sourceTime` when it re-measures is not a seek, and
    /// is invisible here: only item time is fed as the playhead.
    func test_ordinaryPlaybackAfterRelease_staysReleased() {
        var hold = ASSSeekHold()
        playFromStart(&hold)

        play(&hold, from: 1.5, to: 30)

        XCTAssertEqual(hold.renderTime(for: 27), 27)
    }

    /// Leaving PiP reattaches the output, and AVPlayer re-delivers the line on
    /// screen as though it had just started. Rendering carries on without a gap.
    func test_linesReDeliveredAfterPiP_keepRendering() {
        var hold = ASSSeekHold()
        playFromStart(&hold)
        play(&hold, from: 1.5, to: 20)

        hold.ignoreLinesAlreadyShowing()
        hold.observeCues(["A line."], at: 20.1)

        XCTAssertEqual(hold.renderTime(for: 20.1), 20.1)
    }

    /// The styled track starting mid-session, after a seek the hold never saw:
    /// it holds back until a line starts rather than trusting a lead it can't
    /// know was measured.
    func test_createdMidSession_holdsBackUntilALineStarts() {
        var hold = ASSSeekHold()
        XCTAssertNil(hold.renderTime(for: 1480))

        play(&hold, from: 1480, to: 1482)
        XCTAssertNil(hold.renderTime(for: 1482))
        hold.observeCues(["A line."], at: 1482)

        XCTAssertEqual(hold.renderTime(for: 1482), 1482)
    }

    /// Ordinary playback: ticks close enough together not to read as a seek.
    private func play(_ hold: inout ASSSeekHold, from start: TimeInterval, to end: TimeInterval) {
        var time = start
        while time < end {
            time = min(time + 0.25, end)
            hold.observeItemTime(time)
        }
    }

    /// Plays past the first line, which releases the hold — the state a clean
    /// start is in.
    private func playFromStart(_ hold: inout ASSSeekHold) {
        hold.observeItemTime(0)
        hold.observeItemTime(0.5)
        hold.observeCues(["Hello there."], at: 1)
        hold.observeItemTime(1.5)
        precondition(hold.renderTime(for: 1.5) == 1.5)
    }
}
