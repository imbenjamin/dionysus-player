import XCTest
@testable import Dionysus

/// The build switches on AetherEngine's object-audio traits through
/// `Packages/AetherEngineWithObjectAudio`; losing them would quietly hide the
/// settings.
final class SpatialAudioSupportTests: XCTestCase {
    func test_bothComponentsBuiltIn() {
        XCTAssertTrue(SpatialAudioSupport.isBuiltIn(.dolbyAtmos))
        XCTAssertTrue(SpatialAudioSupport.isBuiltIn(.dtsX))
    }

    /// The Simulators the suites run on are OS 26 or later.
    func test_offeredOnThisOS() {
        XCTAssertTrue(SpatialAudioSupport.isOffered(.dolbyAtmos))
        XCTAssertTrue(SpatialAudioSupport.isOffered(.dtsX))
    }
}
