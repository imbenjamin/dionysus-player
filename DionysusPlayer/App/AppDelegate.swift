import UIKit

/// Bridges UIKit's orientation-lock hook into the app. SwiftUI's `App`
/// protocol has no equivalent of
/// `application(_:supportedInterfaceOrientationsFor:)` — a
/// `UIApplicationDelegateAdaptor` (wired up in `DionysusPlayerApp`) is the
/// only way to answer it at all. `RotationLock` is what actually flips the
/// mask this returns and asks UIKit to re-query it once it changes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Primes `DeviceIdentity`'s cached `UIDevice.current` snapshot —
    /// UIKit always calls this on the main thread before anything else in
    /// the app runs, well before the first network request needs it.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        DeviceIdentity.primeCache()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        RotationLock.currentMask()
    }

    /// The system relaunches (or wakes) the app in the background when a
    /// background `URLSessionDownloadTask` (an offline download —
    /// `DownloadManager`) finishes while the app was suspended or
    /// terminated. This is the one hook that hands back the session
    /// identifier to re-attach (which is what actually resumes delivering
    /// the queued delegate callbacks) and a completion handler the OS
    /// expects called once they've all been processed.
    ///
    /// Posted as a notification rather than reaching into `DownloadManager`
    /// directly: `AppDelegate` is constructed by UIKit before any of this
    /// app's own `@State`/`@Observable` object graph exists, so at the
    /// point this can fire there's no guaranteed reference to hand it to
    /// yet — `DownloadManager.init` subscribes to
    /// `.dionysusHandleBackgroundURLSession` itself instead.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        NotificationCenter.default.post(
            name: .dionysusHandleBackgroundURLSession,
            object: nil,
            userInfo: [
                DionysusBackgroundURLSessionUserInfoKey.identifier: identifier,
                // See `BackgroundSessionCompletionBox`'s doc comment for why
                // this can't travel as a bare closure.
                DionysusBackgroundURLSessionUserInfoKey.completionHandler: BackgroundSessionCompletionBox(completionHandler)
            ]
        )
    }
}
