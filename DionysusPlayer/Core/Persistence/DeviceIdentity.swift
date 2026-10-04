import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A stable identifier and readable name identifying this installation to
/// Jellyfin in the `Authorization` header. Generated once and cached in
/// `UserDefaults`: not a secret, just stable across launches.
enum DeviceIdentity {
    private static let deviceIDKey = "device.identifier"

    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIDKey)
        return generated
    }

    /// Cached by `primeCache()` rather than read live: recent SDKs mark
    /// `UIDevice.current` `@MainActor`-isolated, while `deviceName` is read from
    /// the nonisolated `JellyfinAuthorization.headerValue` on every request.
    /// A device's name and idiom don't change mid-session, so one main-actor
    /// snapshot at launch is safe.
    nonisolated(unsafe) private static var cachedDeviceName: String?
    nonisolated(unsafe) private static var cachedIsPad: Bool?

    /// Called once from `AppDelegate`'s launch callback, which UIKit invokes on
    /// the main thread well before the first network request.
    @MainActor
    static func primeCache() {
        #if canImport(UIKit)
        cachedDeviceName = UIDevice.current.name
        cachedIsPad = UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        // A placeholder rather than touching `UIDevice.current` if read before
        // `primeCache()`, which shouldn't happen but beats a crash.
        cachedDeviceName ?? "Unknown Device"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// `true` on iPad, for `DownloadResolution.deviceClassDefault`, so every
    /// UIKit device read stays behind this cache-aware type.
    static var isPad: Bool {
        #if os(iOS)
        cachedIsPad ?? false
        #else
        false
        #endif
    }

    static var clientName: String { "Dionysus" }

    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }
}
