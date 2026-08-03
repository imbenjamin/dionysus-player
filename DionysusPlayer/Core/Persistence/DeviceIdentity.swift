import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A stable device identifier and human-readable name, used to identify this
/// installation to Jellyfin (the `X-Emby-Authorization` header). Generated
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

    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static var clientName: String { "Dionysus Player" }

    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }
}
