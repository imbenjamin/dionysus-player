import Foundation

/// Builds the `X-Emby-Authorization` header Jellyfin (and Emby before it)
/// expects on every request, identifying this app/device and, once signed
/// in, the user's access token.
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
