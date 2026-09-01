import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A stable device identifier and human-readable name, used to identify this
/// installation to Jellyfin (the `Authorization` header). Generated
/// once and cached in `UserDefaults` — it isn't a secret, just needs to be
/// stable across launches.
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

    /// `UIDevice.current`-derived values, cached once by `primeCache()`
    /// rather than read live: recent SDKs mark `UIDevice.current`
    /// `@MainActor`-isolated, but this app reads `deviceName` from a
    /// nonisolated context (`JellyfinAuthorization.headerValue`, called from
    /// the `JellyfinAPIClient` actor to build every request's header). A
    /// device's name/idiom aren't expected to change mid-session, so a
    /// single main-actor snapshot at launch is safe — same "single writer,
    /// no real synchronization needed" reasoning `RotationLock.mask`
    /// documents for its own `nonisolated(unsafe)` flag.
    nonisolated(unsafe) private static var cachedDeviceName: String?
    nonisolated(unsafe) private static var cachedIsPad: Bool?

    /// Called once from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// — a callback UIKit always invokes on the main thread, well before the
    /// first network request or downloads-settings read.
    @MainActor
    static func primeCache() {
        #if canImport(UIKit)
        cachedDeviceName = UIDevice.current.name
        cachedIsPad = UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        // Falls back to a placeholder rather than touching UIDevice.current
        // directly if read before primeCache() has run — this should never
        // happen in practice, but a generic name beats a crash.
        cachedDeviceName ?? "Unknown Device"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// `true` on iPad. Used by `DownloadResolution.deviceClassDefault` so
    /// every UIKit device read lives behind this one already-cache-aware
    /// type instead of touching `UIDevice.current` in two places.
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
