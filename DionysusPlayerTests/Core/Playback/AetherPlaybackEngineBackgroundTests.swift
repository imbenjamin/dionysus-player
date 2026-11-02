import XCTest
@testable import Dionysus

/// A paused title keeps its decode pipeline while the app is in the
/// background, so coming back needs no rebuild (AetherEngine 7.48.0).
@MainActor
final class AetherPlaybackEngineBackgroundTests: XCTestCase {
    func test_pausedSession_keepsItsPipelineInTheBackground() throws {
        let engine = try AetherPlaybackEngine()
        XCTAssertTrue(engine.retainsPausedPipelineInBackground)
    }

    /// Retaining changes nothing about how a torn-down session is recognised:
    /// a paused session that was ready and isn't any more is still reloaded.
    func test_tornDownSession_stillNeedsRecovery() {
        XCTAssertTrue(AetherPlaybackEngine.needsSessionRecovery(isPaused: true, isSessionReady: false, hasSessionBeenReady: true))
        XCTAssertFalse(AetherPlaybackEngine.needsSessionRecovery(isPaused: true, isSessionReady: true, hasSessionBeenReady: true))
    }
}
