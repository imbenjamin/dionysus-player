import XCTest
@testable import Dionysus

/// The calibration that keeps libass on the picture during a server transcode.
///
/// The offsets used here are the two measured on device against Jellyfin 10.11:
/// 1.209s and 3.086s after single seeks.
final class ASSCueTimingCalibratorTests: XCTestCase {
    private let script = """
    [Script Info]
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Arial,20

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello there.
    Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,{\\i1}Maximum{\\i0} effort,\\Nplease.
    Dialogue: 0,0:01:00.00,0:01:02.00,Default,,0,0,0,,Yeah.
    Dialogue: 0,0:01:05.00,0:01:07.00,Default,,0,0,0,,Yeah.
    Dialogue: 0,0:24:43.50,0:24:46.00,Default,,0,0,0,,Say "cheese" & smile.
    Dialogue: 0,0:24:50.00,0:24:52.00,Default,,0,0,0,,The next line.
    """

    // MARK: - Script parsing

    func test_dialogueStarts_keyedByNormalizedText() {
        let starts = ASSCueTimingCalibrator.dialogueStarts(in: script)
        XCTAssertEqual(starts["hello there."], [1])
        XCTAssertEqual(starts["maximum effort, please."], [10.5])
        XCTAssertEqual(starts["yeah."], [60, 65])
    }

    /// `Text` is found by the section's own `Format` line, not by position.
    func test_dialogueStarts_honoursAReorderedFormatLine() {
        let reordered = """
        [Events]
        Format: Start, End, Style, Text
        Dialogue: 0:00:02.25,0:00:04.00,Default,Commas, inside, text
        """
        XCTAssertEqual(ASSCueTimingCalibrator.dialogueStarts(in: reordered)["commas, inside, text"], [2.25])
    }

    func test_dialogueStarts_ignoresCommentsAndOtherSections() {
        let other = """
        [Script Info]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Not an event
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,A comment
        """
        XCTAssertTrue(ASSCueTimingCalibrator.dialogueStarts(in: other).isEmpty)
    }

    /// AetherEngine's WebVTT keeps the line break AVPlayer then presents; the
    /// script has `\N` and override tags. Both must meet in the middle.
    func test_normalize_matchesTheWebVTTFormOfAnEvent() {
        XCTAssertEqual(
            ASSCueTimingCalibrator.normalize("{\\i1}Maximum{\\i0} effort,\\Nplease."),
            ASSCueTimingCalibrator.normalize("Maximum effort,\nplease.")
        )
        XCTAssertEqual(
            ASSCueTimingCalibrator.normalize("<i>Say</i> \"cheese\" &amp; smile."),
            ASSCueTimingCalibrator.normalize("Say \"cheese\" & smile.")
        )
    }

    // MARK: - Calibration

    /// The reported bug: after a scrub the playhead runs ahead of the picture,
    /// and libass on the raw playhead drew each line early. Measured 1.209s.
    func test_afterASeek_rendersAtThePlayheadMinusTheMeasuredOffset() throws {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)

        calibrator.observePlayhead(1480)  // the scrub
        play(&calibrator, from: 1480, to: 1484.5)
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1483.5 + 1.209)

        XCTAssertEqual(calibrator.offset, 1.209, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibrator.renderTime(for: 1490)), 1490 - 1.209, accuracy: 0.0001)
    }

    /// Nothing is painted between a seek and the first line after it: the old
    /// offset is stale and the new one unknown.
    func test_afterASeek_holdsBackUntilALineStarts() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)

        calibrator.observePlayhead(1480)

        XCTAssertNil(calibrator.renderTime(for: 1480))
        play(&calibrator, from: 1480, to: 1482)
        XCTAssertNil(calibrator.renderTime(for: 1482))
    }

    /// A scene with no dialogue can't hold the overlay back forever.
    func test_afterASeek_givesUpWaitingOnTheLastOffset() throws {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)
        calibrator.observePlayhead(1480)

        play(&calibrator, from: 1480, to: 1480 + ASSCueTimingCalibrator.calibrationTimeout)

        XCTAssertEqual(try XCTUnwrap(calibrator.renderTime(for: 1486)), 1486)
    }

    /// A line on screen when the playhead lands is re-delivered at the landing
    /// time, which says nothing about when it started. Reading it as a start
    /// would put the offset seconds too high.
    func test_aLineCarriedOverTheSeek_isNotMeasured() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)

        calibrator.observePlayhead(1485)
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1485.1)

        XCTAssertNil(calibrator.renderTime(for: 1485.1))
        XCTAssertEqual(calibrator.offset, 0)
    }

    /// AVPlayer re-delivers every line still showing whenever another starts,
    /// stamped with the newcomer's time. Only the newcomer measures anything.
    func test_onlyTheLineThatJustStarted_isMeasured() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)
        calibrator.observePlayhead(1482)
        play(&calibrator, from: 1482, to: 1486.5)
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1483.5 + 3.086)
        play(&calibrator, from: 1486.5, to: 1493)

        calibrator.observeCues(["Say \"cheese\" & smile.", "The next line."], at: 1490 + 3.086)

        XCTAssertEqual(calibrator.offset, 3.086, accuracy: 0.0001)
    }

    /// A repeated line matches every event with its text; the one implying the
    /// offset closest to the current one wins.
    func test_aRepeatedLine_matchesTheEventClosestToTheCurrentOffset() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)
        play(&calibrator, from: 1.5, to: 65)

        // "Yeah." starts at 60 and 65. Delivered at 65.02, 60 would imply 5.02.
        calibrator.observeCues(["Yeah."], at: 65.02)

        XCTAssertEqual(calibrator.offset, 0.02, accuracy: 0.0001)
    }

    /// Text the script doesn't have (a server-side conversion quirk, a drawing)
    /// leaves the offset alone rather than guessing.
    func test_anUnmatchedLine_leavesTheOffsetAlone() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)
        calibrator.observePlayhead(1480)
        play(&calibrator, from: 1480, to: 1482)

        calibrator.observeCues(["m 0 0 l 100 0 100 100"], at: 1482)

        XCTAssertNil(calibrator.renderTime(for: 1482))
    }

    /// A line delivered before the tick that would reveal the seek is checked
    /// against the playhead first, so it still counts as a carry-over.
    func test_aCueArrivingBeforeTheSeekTick_stillCountsAsACarryOver() {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)

        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1485.1)

        XCTAssertNil(calibrator.renderTime(for: 1485.1))
        XCTAssertEqual(calibrator.offset, 0)
    }

    /// Leaving PiP reattaches the output, and AVPlayer re-delivers the line on
    /// screen as though it had just started. The offset survives, and rendering
    /// carries on without a gap.
    func test_linesReDeliveredAfterPiP_areNotMeasured() throws {
        var calibrator = ASSCueTimingCalibrator(script: script)
        playFromStart(&calibrator)
        calibrator.observePlayhead(1482)
        play(&calibrator, from: 1482, to: 1484.5)
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1483.5 + 1.209)
        play(&calibrator, from: 1484.75, to: 1486)

        calibrator.ignoreLinesAlreadyShowing()
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1486.1)

        XCTAssertEqual(calibrator.offset, 1.209, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibrator.renderTime(for: 1486.1)), 1486.1 - 1.209, accuracy: 0.0001)
    }

    /// The styled track starting mid-session, after a seek the calibrator never
    /// saw: it holds back until a line measures the offset, rather than
    /// assuming the zero a clean start has.
    func test_createdMidSession_holdsBackUntilMeasured() throws {
        var calibrator = ASSCueTimingCalibrator(script: script)
        XCTAssertNil(calibrator.renderTime(for: 1480))

        play(&calibrator, from: 1480, to: 1484.5)
        XCTAssertNil(calibrator.renderTime(for: 1484.5))
        calibrator.observeCues(["Say \"cheese\" & smile."], at: 1483.5 + 1.209)

        XCTAssertEqual(try XCTUnwrap(calibrator.renderTime(for: 1486)), 1486 - 1.209, accuracy: 0.0001)
    }

    /// Ordinary playback: ticks close enough together not to read as a seek.
    private func play(_ calibrator: inout ASSCueTimingCalibrator, from start: TimeInterval, to end: TimeInterval) {
        var time = start
        while time < end {
            time = min(time + 0.25, end)
            calibrator.observePlayhead(time)
        }
    }

    /// Plays past the first line, which settles a zero offset — the state a
    /// clean start is in, and where the reported bug began.
    private func playFromStart(_ calibrator: inout ASSCueTimingCalibrator) {
        calibrator.observePlayhead(0)
        calibrator.observePlayhead(0.5)
        calibrator.observeCues(["Hello there."], at: 1)
        calibrator.observePlayhead(1.5)
        precondition(calibrator.renderTime(for: 1.5) == 1.5)
    }
}
