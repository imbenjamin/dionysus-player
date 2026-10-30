import XCTest
@testable import Dionysus

/// The software route (whatever the device can't decode in hardware) has no
/// AVPlayer, so its Now Playing comes from AetherEngine only when the app
/// opts in, whichever host owns the native route's.
@MainActor
final class AetherPlaybackEngineNowPlayingTests: XCTestCase {
    /// iOS: the app owns the native route's session too.
    func test_ownedSession_alsoPublishesTheSoftwareRoute() throws {
        let engine = try AetherPlaybackEngine(ownsNowPlayingSession: true)
        XCTAssertTrue(engine.publishesSoftwareNowPlaying)
    }

    /// The Apple TV: AVKit owns the native route's, and has no player to
    /// publish for on the software route.
    func test_avKitHost_stillPublishesTheSoftwareRoute() throws {
        let engine = try AetherPlaybackEngine(ownsNowPlayingSession: false)
        XCTAssertTrue(engine.publishesSoftwareNowPlaying)
    }
}
