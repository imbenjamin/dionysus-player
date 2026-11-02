#if os(tvOS)
import Foundation

/// "Follow Apple TV Users": whether each Apple TV user keeps their own
/// Dionysus session (on, the default) or everyone shares one (off). Stored in
/// the keychain every Apple TV user shares, because tvOS's user-switching bug
/// can launch the app in any user's container; a per-container value would
/// flip with it.
enum SessionScopeSetting {
    private static let key = "settings.followsAppleTVUsers"
    private static let selectsUserKey = "settings.selectsUserEveryRelaunch"

    static var followsAppleTVUsers: Bool { flag(key) }

    /// "Select a User Every Relaunch": with one shared session, whether each
    /// launch starts at Who's Watching? (on, the default) or stays on whoever
    /// was signed in. Only read while `followsAppleTVUsers` is off
    /// (`WhoIsWatchingPolicy`); kept through it being on.
    static var selectsUserEveryRelaunch: Bool { flag(selectsUserKey) }

    static func setSelectsUserEveryRelaunch(_ selects: Bool) {
        KeychainStore.save(Data([selects ? 1 : 0]), forKey: selectsUserKey, scope: .allUsers)
    }

    /// Both settings are on unless turned off.
    private static func flag(_ key: String) -> Bool {
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
        KeychainStore.delete(forKey: selectsUserKey, scope: .allUsers)
    }
}

/// When the app starts at Who's Watching? although someone is signed in
/// (Benjamin, 2026-10-01): with one session shared by every Apple TV user
/// (`followsAppleTVUsers` off) and "Select a User Every Relaunch" on, each
/// launch, and each return after half an hour away, asks who it is.
enum WhoIsWatchingPolicy {
    /// tvOS suspends the app through sleep and resumes it, so time away
    /// stands in for a relaunch. Short enough to catch the next sitting, long
    /// enough that a trip to the Home Screen doesn't ask.
    static let timeAway: TimeInterval = 30 * 60

    /// With one remembered account there's nothing to choose, so it signs
    /// straight in.
    static func asks(followsAppleTVUsers: Bool, selectsUserEveryRelaunch: Bool, rememberedAccounts: Int) -> Bool {
        !followsAppleTVUsers && selectsUserEveryRelaunch && rememberedAccounts > 1
    }

    static func asks(afterSecondsAway seconds: TimeInterval) -> Bool { seconds >= timeAway }
}
#endif
