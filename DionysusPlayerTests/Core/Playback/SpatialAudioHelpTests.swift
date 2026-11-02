import XCTest
@testable import Dionysus

/// The About Spatial Audio page, shared by both apps (iOS's Learn More sheet,
/// the Apple TV's About row).
final class SpatialAudioHelpTests: XCTestCase {
    func test_paragraphs_areTheThreeInOrder() {
        let paragraphs = SpatialAudioHelp.paragraphs
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertTrue(paragraphs.first?.hasPrefix("Dolby TrueHD and DTS-HD Master Audio") == true)
        XCTAssertTrue(paragraphs.last?.hasPrefix("Choose the speaker layout") == true)
    }

    /// The bed goes out as lossless PCM since AetherEngine 7.50.0, and the
    /// page names every indicator a receiver may light for it (Benjamin,
    /// 2026-10-30), so nobody reads "Multichannel PCM" as the feature failing.
    func test_paragraphs_sayLosslessAndNameTheReceiverIndicators() {
        let text = SpatialAudioHelp.paragraphs.joined(separator: " ")
        for phrase in ["lossless", "Dolby Atmos", "Multichannel PCM", "LPCM", "never shows as DTS:X"] {
            XCTAssertTrue(text.contains(phrase), "missing \"\(phrase)\"")
        }
        XCTAssertFalse(text.contains("re-encode"), "the bed is no longer re-encoded")
    }

    /// App Review rejects a store build with a feature labelled beta
    /// (guideline 2.2).
    func test_paragraphs_neverCallTheFeatureABeta() {
        for paragraph in SpatialAudioHelp.paragraphs {
            for word in ["beta", "experimental", "known issue"] {
                XCTAssertFalse(paragraph.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(paragraph)")
            }
        }
    }
}
