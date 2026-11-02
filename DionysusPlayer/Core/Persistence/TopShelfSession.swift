import Foundation

/// What the Top Shelf extension needs to fetch (M6). The extension reads the
/// default Apple TV profile's keychain whichever profile is active (spike,
/// 2026-10-14), so it can't read the current user's credentials; the app
/// mirrors its session here, in the keychain every profile shares, each time
/// it's used, and the shelf shows whoever last used Dionysus (Benjamin). The
/// device id and name travel with the token: a token presented with another
/// device id risks Jellyfin revoking the session.
struct TopShelfSession: Codable, Equatable {
    var serverURL: URL
    var serverID: String
    var userID: String
    var accessToken: String
    var deviceID: String
    var deviceName: String

    static let keychainKey = "topshelf.session"

    static func make(
        server: ServerConfiguration?, credentials: StoredCredentials?, deviceID: String, deviceName: String
    ) -> TopShelfSession? {
        guard let server, let credentials,
              let token = credentials.accessToken, !token.isEmpty,
              let userID = credentials.userID,
              credentials.serverID == nil || credentials.serverID == server.id
        else { return nil }
        return TopShelfSession(
            serverURL: server.baseURL, serverID: server.id, userID: userID,
            accessToken: token, deviceID: deviceID, deviceName: deviceName
        )
    }
}

enum TopShelfSessionMirror {
    /// `nil` deletes the mirror (signing out).
    static func write(_ session: TopShelfSession?) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            KeychainStore.delete(forKey: TopShelfSession.keychainKey, scope: .allUsers)
            return
        }
        KeychainStore.save(data, forKey: TopShelfSession.keychainKey, scope: .allUsers)
    }

    static func read() -> TopShelfSession? {
        KeychainStore.load(forKey: TopShelfSession.keychainKey, scope: .allUsers)
            .flatMap { try? JSONDecoder().decode(TopShelfSession.self, from: $0) }
    }
}
