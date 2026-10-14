import SwiftUI

/// What a Top Shelf link does on arrival (M6). A link waits while the session
/// restores (a cold launch from the shelf), and is dropped when nobody is
/// signed in or it was built for another server: the shelf may be a few
/// minutes older than a sign-out or a server change.
enum TVDeepLinkRouter {
    enum Decision: Equatable {
        case wait
        case ignore
        case openDetail(itemID: String)
        case play(itemID: String)
    }

    static func decide(_ link: TVDeepLink, isRestoringSession: Bool, isSignedIn: Bool, serverID: String?) -> Decision {
        if isRestoringSession { return .wait }
        guard isSignedIn, serverID == link.serverID else { return .ignore }
        switch link.action {
        case .item: return .openDetail(itemID: link.itemID)
        case .play: return .play(itemID: link.itemID)
        }
    }
}

extension EnvironmentValues {
    /// A Top Shelf link for `TVMainView` to apply; set by `TVRootView`, which
    /// clears it once applied.
    @Entry var tvPendingDeepLink: TVDeepLink? = nil
    @Entry var tvDeepLinkApplied: @MainActor () -> Void = {}
}
