import XCTest
@testable import Dionysus

final class TVPlayerSurfacePolicyTests: XCTestCase {
    /// Native route: AVKit renders the engine's AVPlayer, and the engine's own
    /// view must leave the stack, or its layer covers the video (spike:
    /// sound, mode switch, black picture).
    func test_nativeRoute_handsPlayerToAVKit_andHidesEngineView() {
        XCTAssertEqual(
            TVPlayerSurfacePolicy.surface(nativePlayerAvailable: true),
            TVPlayerSurface(avKitRendersPlayer: true, engineViewVisible: false)
        )
    }

    /// Software route: no AVPlayer exists, so AVKit must drop its player (or
    /// it draws a spinner over the frames) and the engine view renders.
    func test_softwareRoute_clearsAVKitPlayer_andShowsEngineView() {
        XCTAssertEqual(
            TVPlayerSurfacePolicy.surface(nativePlayerAvailable: false),
            TVPlayerSurface(avKitRendersPlayer: false, engineViewVisible: true)
        )
    }
}
