import Foundation

/// Whether a `DeepLink` can be applied to the session as it stands (#406).
/// Pure, so both apps share it; what applying means is each app's own.
enum DeepLinkRouter {
    enum Refusal: Equatable, Sendable {
        case signedOut
        /// The link names a server other than the signed-in one. Never
        /// switches servers.
        case otherServer
        /// The link names a user other than the signed-in one. Never
        /// switches users.
        case otherUser
    }

    enum Decision: Equatable, Sendable {
        /// The session is still restoring (a cold launch from the link);
        /// ask again once it has.
        case wait
        case refuse(Refusal)
        case apply
    }

    static func decide(
        _ link: DeepLink,
        isRestoringSession: Bool,
        isSignedIn: Bool,
        serverID: String?,
        userID: String?
    ) -> Decision {
        if isRestoringSession { return .wait }
        guard isSignedIn else { return .refuse(.signedOut) }
        if let linkServer = link.serverID, linkServer != serverID { return .refuse(.otherServer) }
        if let linkUser = link.userID, linkUser != userID { return .refuse(.otherUser) }
        return .apply
    }

    /// Whether a link being applied may go on after an await. Applying takes
    /// a few (the closing player, the item's fetch), and a sign-out in
    /// between must end it: on return after a while tvOS can hand the app
    /// the link before Who's Watching? signs out, and the player would
    /// otherwise open over the picker on the last user's account (M6 review).
    static func canFinish(appliedFor userID: String, isSignedIn: Bool, signedInUserID: String?) -> Bool {
        isSignedIn && signedInUserID == userID
    }
}
