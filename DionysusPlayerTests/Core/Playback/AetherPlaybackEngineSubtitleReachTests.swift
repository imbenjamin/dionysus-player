import XCTest
@testable import Dionysus

/// The app applies no subtitle offset, so it declares a reach of 0 and
/// AetherEngine reads embedded subtitles from the main reader alone, instead
/// of downloading a remote source a second time (AE#1015, 7.62.1).
@MainActor
final class AetherPlaybackEngineSubtitleReachTests: XCTestCase {
    func test_declaresNoSubtitleOffsetReach() throws {
        XCTAssertEqual(try AetherPlaybackEngine().subtitleOffsetReachSeconds, 0)
    }

    /// The Apple TV host's engine is made the same way.
    func test_declaresNoSubtitleOffsetReach_forTheAVKitHost() throws {
        XCTAssertEqual(try AetherPlaybackEngine(ownsNowPlayingSession: false).subtitleOffsetReachSeconds, 0)
    }
}
