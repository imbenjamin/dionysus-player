import AVKit
import XCTest
@testable import Dionysus

/// The engine holds the outgoing picture through an audio switch on an
/// `AetherStillView`, since AVKit, not the engine's own view, draws the native
/// route here.
@MainActor
final class TVPlayerHostStillViewTests: XCTestCase {
    func test_aetherEngine_getsAStillViewOverTheVideo() throws {
        let host = TVPlayerHostController(viewModel: try makeViewModel(engine: AetherPlaybackEngine(ownsNowPlayingSession: false)))
        host.loadViewIfNeeded()

        let still = try XCTUnwrap(host.stillView)
        let surfaceHost = try XCTUnwrap(host.contentOverlayView)
        // Topmost in the overlay view, so above the engine's own view.
        XCTAssertTrue(surfaceHost.subviews.last === still)
        XCTAssertFalse(still.isUserInteractionEnabled)
        XCTAssertEqual(still.videoGravity, host.videoGravity)
    }

    /// The UI-test harness's fake engine has nothing to hold a picture with.
    func test_fakeEngine_getsNoStillView() {
        let host = TVPlayerHostController(viewModel: makeViewModel(engine: FakePlaybackEngine()))
        host.loadViewIfNeeded()

        XCTAssertNil(host.stillView)
    }

    private func makeViewModel(engine: PlaybackEngine) -> PlayerViewModel {
        PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine
        )
    }
}
