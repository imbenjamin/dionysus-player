import Foundation

/// Builds the value of the `Authorization` header (`MediaBrowser` scheme)
/// Jellyfin expects on every request, identifying this app/device and, once
/// signed in, the user's access token. This is the non-deprecated form —
/// Jellyfin 12.0 disables the legacy `X-Emby-Authorization`/`X-Emby-Token`
/// headers by default, but `Authorization`/`MediaBrowser` predates that and
/// is accepted by both 10.x and 12.0 servers.
enum JellyfinAuthorization {
    static func headerValue(token: String?) -> String {
        var parts = [
            "Client=\"\(DeviceIdentity.clientName)\"",
            "Device=\"\(DeviceIdentity.deviceName)\"",
            "DeviceId=\"\(DeviceIdentity.deviceID)\"",
            "Version=\"\(DeviceIdentity.clientVersion)\""
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}
