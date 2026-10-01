#if os(tvOS)
import Foundation

/// "Follow Apple TV Users": whether each Apple TV user keeps their own
/// Dionysus session (on, the default) or everyone shares one (off). Stored in
/// the keychain every Apple TV user shares, because tvOS's user-switching bug
/// can launch the app in any user's container; a per-container value would
/// flip with it.
enum SessionScopeSetting {
    private static let key = "settings.followsAppleTVUsers"

    static var followsAppleTVUsers: Bool {
        guard let data = KeychainStore.load(forKey: key, scope: .allUsers) else { return true }
        return data != Data([0])
    }

    /// Where the credentials and remembered accounts live under the setting.
    static var sessionScope: KeychainStore.Scope {
        followsAppleTVUsers ? .currentUser : .allUsers
    }

    static func set(_ follows: Bool) {
        KeychainStore.save(Data([follows ? 1 : 0]), forKey: key, scope: .allUsers)
    }

    /// Back to the default, for the UI-test harness's reset.
    static func reset() {
        KeychainStore.delete(forKey: key, scope: .allUsers)
    }
}
#endif
