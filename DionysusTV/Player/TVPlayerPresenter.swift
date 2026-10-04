import UIKit

/// Presents the player with UIKit, never `fullScreenCover`, which takes the
/// Menu press away from the controller. The page beneath stays as it is, so
/// leaving the player is immediate and focus is still on the title played
/// (Benjamin, 2026-10-01).
enum TVPlayerPresenter {
    /// `request.itemID` must be directly playable: a movie or an episode.
    /// `queue` is the playlist being played through, empty otherwise.
    /// Returns whether the player was presented.
    @MainActor @discardableResult
    static func present(
        _ request: PlaybackRequest,
        queue: [MediaItem] = [],
        client: JellyfinAPIClient,
        userID: String,
        onClose: (@MainActor (PlaybackSessionOutcome) -> Void)? = nil
    ) -> Bool {
        guard let engine = makeEngine() else { return false }
        let viewModel = PlayerViewModel(
            client: client, userID: userID, itemID: request.itemID, engine: engine,
            startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
            playbackQueue: queue
        )
        let host = TVPlayerHostController(viewModel: viewModel, engine: engine)
        host.onClose = onClose
        host.modalPresentationStyle = .fullScreen
        guard let presenter = topViewController() else { return false }
        presenter.present(host, animated: true)
        return true
    }

    /// Closes the player if it's up, as Menu does.
    @MainActor
    static func dismissPlayer() {
        (topViewController() as? TVPlayerHostController)?.close()
    }

    /// The harness's fake under UI tests; otherwise AetherEngine, without Now
    /// Playing, which AVKit owns under this host.
    @MainActor
    private static func makeEngine() -> PlaybackEngine? {
        #if DEBUG
        if UITestConfiguration.isActive { return try? PlaybackEngineFactory.make() }
        #endif
        return try? AetherPlaybackEngine(ownsNowPlayingSession: false)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
