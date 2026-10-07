import UIKit

/// The player's host, as `TVPlayerPresenter` recognises it in the presented
/// chain.
protocol TVPlayerPresentation: UIViewController {}

/// Presents the player with UIKit, never `fullScreenCover`, which takes the
/// Menu press away from the controller. The page beneath stays as it is, so
/// leaving the player is immediate and focus is still on the title played
/// (Benjamin, 2026-10-01).
enum TVPlayerPresenter {
    /// `request.itemID` must be directly playable: a movie or an episode.
    /// `queue` is the playlist being played through, empty otherwise.
    /// Returns whether the player was presented: not while one is already up
    /// or still coming up (`canPresent(over:)`).
    @MainActor @discardableResult
    static func present(
        _ request: PlaybackRequest,
        queue: [MediaItem] = [],
        client: JellyfinAPIClient,
        userID: String,
        onClose: (@MainActor (PlaybackSessionOutcome) -> Void)? = nil
    ) -> Bool {
        guard canPresent(over: presentedChain()), let engine = makeEngine() else { return false }
        let viewModel = PlayerViewModel(
            client: client, userID: userID, itemID: request.itemID, engine: engine,
            startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
            playbackQueue: queue
        )
        let host = TVPlayerHostController(viewModel: viewModel)
        host.onClose = onClose
        host.makeViewModel = { itemID in
            guard let engine = makeEngine() else { return nil }
            return PlayerViewModel(client: client, userID: userID, itemID: itemID, engine: engine, playbackQueue: queue)
        }
        host.modalPresentationStyle = .fullScreen
        guard let presenter = presentedChain().last else { return false }
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

    /// `chain` runs from the window's root to the top presented controller.
    /// A second Play while a player is in it is refused (M3 review): an
    /// impatient second Select on the hero, landing after its Next Up lookup,
    /// stacked a second player, or pushed a second detail page whose player
    /// never closed. UIKit sets `presentedViewController` as soon as
    /// `present` is called, so a player still animating in counts.
    static func canPresent(over chain: [UIViewController]) -> Bool {
        !chain.isEmpty && !chain.contains { $0 is TVPlayerPresentation }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        presentedChain().last
    }

    @MainActor
    private static func presentedChain() -> [UIViewController] {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var chain: [UIViewController] = []
        var next = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        return chain
    }
}
