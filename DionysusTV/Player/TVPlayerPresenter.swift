import UIKit

/// Presents the player with UIKit, never `fullScreenCover`, which takes the
/// Menu press away from the controller.
enum TVPlayerPresenter {
    @MainActor
    static func present(item: MediaItem, client: JellyfinAPIClient, userID: String) {
        // Milestone 3: resolve a Series via PlaybackRequest. The launcher only
        // shows movies and episodes, so the item's own id plays.
        present(itemID: item.id, client: client, userID: userID)
    }

    /// `itemID` must be directly playable: a movie or an episode.
    @MainActor
    static func present(itemID: String, client: JellyfinAPIClient, userID: String) {
        guard let engine = makeEngine() else { return }
        let viewModel = PlayerViewModel(client: client, userID: userID, itemID: itemID, engine: engine)
        let host = TVPlayerHostController(viewModel: viewModel, engine: engine)
        host.modalPresentationStyle = .fullScreen
        topViewController()?.present(host, animated: true)
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
