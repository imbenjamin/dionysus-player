import SwiftUI

/// Where a `dionysus://` link lands on iPhone and iPad (#406), decided before
/// anything moves, so the mapping is unit-tested apart from `MainTabView`,
/// which carries it out.
///
/// A title's page is pushed on Home's stack, its path replaced, so Back
/// returns to Home, as on the Apple TV. A play link pushes the same page and
/// cues it to play (`DeepLinkPlaybackCue`): the page then does what its own
/// Play does, so the player opens over it, remembers the page's resume and
/// version choices, and refreshes the page when it closes. A playlist member
/// (`?playlist=`) is played from the playlist's page, which queues the rest;
/// a downloaded title, asked for (`?offline=1`) or while offline, from its
/// download's page.
struct DeepLinkNavigation: Equatable {
    enum Tab: Equatable {
        case home, search, downloads, profile
    }

    var tab: Tab
    /// Home's stack after the link; nil leaves it as it is.
    var homePath: [AppRoute]?
    /// Search's query to fill in and run; nil leaves Search as it is.
    var searchQuery: String?
    /// The page on top of Home's stack plays this as soon as it has loaded.
    var playback: DeepLinkPlaybackCue.Cue?

    /// Nil for a destination iPhone and iPad don't open (yet): the app stays
    /// where it is and says so. `issues` are what the link couldn't read;
    /// `isDownloaded` says whether a title has a finished download, and
    /// `isOffline` whether the app is.
    static func plan(
        for destination: DeepLink.Destination, issues: [DeepLink.Issue] = [],
        isDownloaded: (String) -> Bool = { _ in false }, isOffline: Bool = false
    ) -> DeepLinkNavigation? {
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
            DeepLinkNavigation(tab: .home, homePath: [
                isOffline && isDownloaded(id) ? .downloadedAsset(itemID: id) : .assetDetail(itemID: id),
            ])
        case .downloaded(let id):
            DeepLinkNavigation(tab: .home, homePath: [.downloadedAsset(itemID: id)])
        case .play(let id, let options):
            playPlan(id: id, options: options, issues: issues, isDownloaded: isDownloaded, isOffline: isOffline)
        case .library, .quickConnectApproval, .serverSetup:
            nil
        }
    }

    private static func playPlan(
        id: String, options: DeepLink.PlaybackOptions, issues: [DeepLink.Issue],
        isDownloaded: (String) -> Bool, isOffline: Bool
    ) -> DeepLinkNavigation {
        var overrides = PlaybackLinkOverrides(options, issues: issues)
        if let playlistID = options.playlistID {
            return DeepLinkNavigation(
                tab: .home, homePath: [.assetDetail(itemID: playlistID)],
                playback: .init(pageID: playlistID, memberID: id, overrides: overrides)
            )
        }
        if isDownloaded(id), options.prefersDownload || isOffline {
            return DeepLinkNavigation(
                tab: .home, homePath: [.downloadedAsset(itemID: id)],
                playback: .init(pageID: id, playsDownload: true, overrides: overrides)
            )
        }
        if options.prefersDownload {
            overrides.notices.append(String(localized: "This title isn't downloaded, so it's streaming."))
        }
        return DeepLinkNavigation(
            tab: .home, homePath: [.assetDetail(itemID: id)], playback: .init(pageID: id, overrides: overrides)
        )
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
