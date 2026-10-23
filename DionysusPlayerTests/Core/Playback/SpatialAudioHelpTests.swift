import XCTest
@testable import Dionysus

/// The About Spatial Audio page, shared by both apps (iOS's Learn More sheet,
/// the Apple TV's About row).
final class SpatialAudioHelpTests: XCTestCase {
    func test_paragraphs_areTheFourInOrder() {
        let paragraphs = SpatialAudioHelp.paragraphs
        XCTAssertEqual(paragraphs.count, 4)
        XCTAssertTrue(paragraphs.first?.hasPrefix("Dolby TrueHD and DTS-HD Master Audio") == true)
        XCTAssertTrue(paragraphs.last?.hasPrefix("Re-encoding takes a lot of processing power") == true)
    }

    /// App Review rejects a store build with a feature labelled beta
    /// (guideline 2.2), so the stall caveat is a plain limitation.
    func test_paragraphs_neverCallTheFeatureABeta() {
        for paragraph in SpatialAudioHelp.paragraphs {
            for word in ["beta", "experimental", "known issue"] {
                XCTAssertFalse(paragraph.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(paragraph)")
            }
        }
    }
}
