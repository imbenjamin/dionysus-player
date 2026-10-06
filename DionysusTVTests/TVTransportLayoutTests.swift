import XCTest
@testable import Dionysus

final class TVTransportLayoutTests: XCTestCase {
    func test_fraction_isClampedAndSafeWithoutADuration() {
        XCTAssertEqual(TVTransportLayout.fraction(2700, duration: 5400), 0.5)
        XCTAssertEqual(TVTransportLayout.fraction(6000, duration: 5400), 1)
        XCTAssertEqual(TVTransportLayout.fraction(10, duration: 0), 0)
    }

    func test_bufferedFraction_runsFromThePlayheadOn_andIsAbsentWithoutAReading() {
        XCTAssertEqual(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: 540, duration: 5400) ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(TVTransportLayout.bufferedFraction(currentTime: 5300, bufferedSeconds: 540, duration: 5400), 1)
        XCTAssertNil(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: nil, duration: 5400))
        XCTAssertNil(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: 30, duration: 0))
    }

    func test_previewCenter_staysOnTheTrack() {
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 0.5, trackWidth: 1760, previewWidth: 400), 880)
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 0, trackWidth: 1760, previewWidth: 400), 200)
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 1, trackWidth: 1760, previewWidth: 400), 1560)
    }

    func test_previewCaption_namesTheChapterWhenThereIsOne() {
        XCTAssertEqual(TVTransportLayout.previewCaption(time: 3135, chapterName: "The Radio Broadcast"), "52:15 · The Radio Broadcast")
        XCTAssertEqual(TVTransportLayout.previewCaption(time: 3135, chapterName: nil), "52:15")
    }

    /// The chip shows only what the engine reports as presented, and nothing
    /// for SDR, whose description is nil (Benjamin, 2026-10-06).
    func test_formatChip_onlyWhileTheEngineReportsHDR() {
        XCTAssertEqual(TVTransportLayout.formatChipText("Dolby Vision"), "DOLBY VISION")
        XCTAssertNil(TVTransportLayout.formatChipText(nil))
    }
}
