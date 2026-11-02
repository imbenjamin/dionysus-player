import Foundation
import Security

/// Minimal wrapper around the Keychain Services API for storing small
/// secrets (credentials, tokens) as opaque `Data` blobs.
enum KeychainStore {
    /// Whose keychain an item lives in. Only tvOS tells them apart: running as
    /// the current Apple TV user, each user has their own keychain, and
    /// `.allUsers` items go to the one every user shares
    /// (`kSecUseUserIndependentKeychain`). iOS has one user, so there the two
    /// are the same keychain.
    enum Scope {
        case currentUser
        case allUsers
    }

    private static let service = "com.dionysusplayer.ios.credentials"

    private static func baseQuery(forKey key: String, scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        #if os(tvOS)
        if scope == .allUsers {
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        }
        #endif
        return query
    }

    @discardableResult
    static func save(_ data: Data, forKey key: String, scope: Scope = .currentUser) -> OSStatus {
        let query = baseQuery(forKey: key, scope: scope)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(forKey key: String, scope: Scope = .currentUser) -> Data? {
        var query = baseQuery(forKey: key, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(forKey key: String, scope: Scope = .currentUser) {
        SecItemDelete(baseQuery(forKey: key, scope: scope) as CFDictionary)
    }
}
