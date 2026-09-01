import UIKit

/// Locks the device's interface orientation to whatever it currently is, for
/// `PlayerControlsOverlay`'s rotation-lock button. SwiftUI has no
/// orientation-lock API of its own; the only hook UIKit offers at all is the
/// app delegate's `application(_:supportedInterfaceOrientationsFor:)` (see
/// `AppDelegate`), so this is the bridge between a button tap and that hook.
///
/// Deliberately app-wide, static state rather than something owned per-
/// `PlayerView` instance: `AppDelegate`'s method has no way to reach into a
/// particular SwiftUI view's `@State` to ask whether it wants a lock, so the
/// mask it returns has to live somewhere both sides can reach regardless of
/// who's toggling it.
enum RotationLock {
    /// What `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
    /// returns. `nonisolated(unsafe)` because UIKit can call that delegate
    /// method from a context Swift doesn't statically know is the main actor,
    /// while every write here happens on it already (`lockToCurrentOrientation()`/
    /// `unlock()` below are both `@MainActor`) — a single flag with one
    /// writer at a time, not shared mutable state that needs real
    /// synchronization.
    private nonisolated(unsafe) static var mask: UIInterfaceOrientationMask = .all

    /// Read by `AppDelegate`. Deliberately not `@MainActor`-isolated itself,
    /// so it can be called from whatever context UIKit invokes the delegate
    /// hook on without a compiler error.
    static func currentMask() -> UIInterfaceOrientationMask { mask }

    /// Locks rotation to whichever orientation the device is in right now.
    /// `PlayerView`'s rotation-lock button calls this, and pairs it with
    /// `unlock()` once playback closes — without that, the rest of the app
    /// would be stuck in whatever orientation the player happened to be
    /// locked to.
    @MainActor
    static func lockToCurrentOrientation() {
        guard let orientation = keyWindowScene?.interfaceOrientation else { return }
        mask = maskMatching(orientation)
        notifyUIKit()
    }

    /// Restores free rotation (within whatever this device's own
    /// `UISupportedInterfaceOrientations` Info.plist entry already allows —
    /// `.all` doesn't need to special-case iPhone vs iPad itself, since
    /// UIKit intersects it against that regardless).
    @MainActor
    static func unlock() {
        mask = .all
        notifyUIKit()
    }

    private static func maskMatching(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .unknown: return .all
        @unknown default: return .all
        }
    }

    /// Tells UIKit to re-query `AppDelegate`'s hook immediately — without
    /// this, the new mask would only take effect the next time UIKit happens
    /// to re-check supported orientations on its own (e.g. the next rotation
    /// attempt), not right when the button is tapped.
    @MainActor
    private static func notifyUIKit() {
        keyWindowScene?.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Same lookup `HeroRailView`/`HeroHeaderView` use for their own
    /// key-window access.
    @MainActor
    private static var keyWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }
}
