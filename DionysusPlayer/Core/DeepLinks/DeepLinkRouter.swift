import Foundation

/// A link the app has received but not yet applied, with what's needed to
/// decide later whether it still should be.
struct PendingDeepLink: Equatable, Sendable {
    var link: DeepLink
    var receivedAt: Date
    /// The configured server when the link arrived, if any. A link held
    /// through sign-in is dropped if the user ends up on another server.
    var serverIDAtArrival: String?
}

/// Whether a `DeepLink` can be applied to the session as it stands (#406).
/// Pure, so both apps share it; what applying means is each app's own.
enum DeepLinkRouter {
    /// How long a link waits for someone to sign in. Longer, and it would
    /// open on its own long after anyone remembers asking for it.
    static let signInHoldLimit: TimeInterval = 10 * 60

    enum Refusal: Equatable, Sendable {
        /// Held through sign-in for longer than `signInHoldLimit`.
        case expired
        /// Held through sign-in, and the user signed in to another server.
        case serverChanged
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
        /// Nobody is signed in: keep the link and ask again after sign-in.
        case waitForSignIn
        case refuse(Refusal)
        case apply
    }

    static func decide(
        _ pending: PendingDeepLink,
        now: Date,
        isRestoringSession: Bool,
        isSignedIn: Bool,
        serverID: String?,
        userID: String?
    ) -> Decision {
        if isRestoringSession { return .wait }
        guard now.timeIntervalSince(pending.receivedAt) <= signInHoldLimit else { return .refuse(.expired) }
        guard isSignedIn else { return .waitForSignIn }
        if let arrival = pending.serverIDAtArrival, arrival != serverID { return .refuse(.serverChanged) }
        if let linkServer = pending.link.serverID, linkServer != serverID { return .refuse(.otherServer) }
        if let linkUser = pending.link.userID, linkUser != userID { return .refuse(.otherUser) }
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

extension DeepLinkRouter.Refusal {
    /// What the app says when it refuses; nil for a refusal that stays
    /// silent, where whatever asked for the link is long gone.
    var message: String? {
        switch self {
        case .expired, .serverChanged: nil
        case .otherServer: String(localized: "This link is for another server.")
        case .otherUser: String(localized: "This link is for another user.")
        }
    }
}

extension DeepLink {
    /// What the app says about a `dionysus://` URL it can't read, or a
    /// destination this platform doesn't open.
    static var cantOpenMessage: String { String(localized: "This link can't be opened.") }
}
