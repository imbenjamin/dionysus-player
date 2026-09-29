import XCTest
import AetherEngine
@testable import Dionysus

final class AetherPlaybackEngineLoadOptionsTests: XCTestCase {
    /// tvOS's Match Content setting and the panel's live HDR state reach the
    /// engine, as AetherEngine's "Host setup on tvOS" and Sodalite pass them.
    func test_displayContext_isPassedThrough() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [],
            display: DisplayContext(matchContentEnabled: false, panelIsInHDRMode: true)
        )
        XCTAssertFalse(options.matchContentEnabled)
        XCTAssertTrue(options.panelIsInHDRMode)
        XCTAssertFalse(options.suppressDisplayCriteria, "The engine must stay the only criteria writer")
    }

    /// With no window to ask (Review Focus 2), the engine's own defaults apply:
    /// matching assumed on, panel state unproven.
    func test_unknownDisplay_keepsEngineDefaults() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertFalse(options.panelIsInHDRMode)
        XCTAssertTrue(options.attemptsHDRMasterOnUnprovenPanel)
    }

    /// The iOS behaviour is unchanged: the same remote-HLS and subtitle flags as before.
    func test_existingFlags_unchanged() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: true, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.nativeRemoteHLS)
        XCTAssertTrue(options.prepareNativeSubtitles)
        XCTAssertFalse(options.isLive)
    }
}
