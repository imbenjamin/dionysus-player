import UIKit

/// Bridges UIKit's orientation-lock hook into the app. SwiftUI's `App`
/// protocol has no equivalent of
/// `application(_:supportedInterfaceOrientationsFor:)` — a
/// `UIApplicationDelegateAdaptor` (wired up in `DionysusPlayerApp`) is the
/// only way to answer it at all. `RotationLock` is what actually flips the
/// mask this returns and asks UIKit to re-query it once it changes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        RotationLock.currentMask()
    }
}
