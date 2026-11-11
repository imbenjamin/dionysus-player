import SwiftUI

/// Where a `dionysus://` link lands on iPhone and iPad (#406), decided before
/// anything moves, so the mapping is unit-tested apart from `MainTabView`,
/// which carries it out.
///
/// A title's page is pushed on Home's stack, its path replaced, so Back
/// returns to Home, as on the Apple TV. A play link pushes the same page and
/// cues it to play (`DeepLinkPlaybackCue`): the page then does what its own
/// Play does, so the player opens over it, remembers the page's resume and
/// version choices, and refreshes the page when it closes.
struct DeepLinkNavigation: Equatable {
    enum Tab: Equatable {
        case home, search, downloads, profile
    }

    var tab: Tab
    /// Home's stack after the link; nil leaves it as it is.
    var homePath: [AppRoute]?
    /// Search's query to fill in and run; nil leaves Search as it is.
    var searchQuery: String?
    /// The page on top of Home's stack plays as soon as it has loaded.
    var playsItemID: String?

    /// Nil for a destination iPhone and iPad don't open (yet): the app stays
    /// where it is and says so.
    static func plan(for destination: DeepLink.Destination) -> DeepLinkNavigation? {
        switch destination {
        case .home:
            DeepLinkNavigation(tab: .home, homePath: [])
        case .search(let query):
            DeepLinkNavigation(tab: .search, searchQuery: query)
        case .downloads:
            DeepLinkNavigation(tab: .downloads)
        case .profile:
            // Profile's own pages arrive with #406's fourth step.
            DeepLinkNavigation(tab: .profile)
        case .item(let id, _):
            DeepLinkNavigation(tab: .home, homePath: [.assetDetail(itemID: id)])
        case .play(let id, _):
            DeepLinkNavigation(tab: .home, homePath: [.assetDetail(itemID: id)], playsItemID: id)
        case .library, .downloaded, .quickConnectApproval, .serverSetup:
            nil
        }
    }
}

extension EnvironmentValues {
    /// A link for `MainTabView` to apply, once `RootView` has decided it can
    /// (`DeepLinkRouter`); `RootView` clears it when told it's applied.
    @Entry var pendingDeepLink: DeepLink? = nil
    @Entry var deepLinkApplied: @MainActor () -> Void = {}
}

/// A search a link asked for; a new id runs it again even when the text
/// is the same.
struct LinkedSearchQuery: Equatable {
    let id = UUID()
    let query: String
}
