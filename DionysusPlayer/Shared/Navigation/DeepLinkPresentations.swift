import UIKit

/// Clears what's presented over the tabs before a link moves them (#406):
/// the player first, closed as its close button does so its stop is
/// reported (`PlayerCloseRequest`), then any sheet left above the tabs.
@MainActor
enum DeepLinkPresentations {
    /// How long the player gets to report its stop and go (its close waits
    /// on the report, which a slow server can take seconds over). Past it,
    /// the link carries on and the sheet dismissal below takes the player
    /// too, unreported.
    static let playerCloseLimit: Duration = .seconds(10)

    static func clear() async {
        let closer = PlayerCloseRequest.shared
        if closer.isPlayerUp {
            closer.closeAll()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: playerCloseLimit)
            while closer.isPlayerUp, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard let root = rootViewController, root.presentedViewController != nil else { return }
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
