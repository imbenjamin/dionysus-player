import Foundation

/// Stable, non-localized identifiers for the elements UI tests drive.
///
/// Compiled into both the app and `DionysusPlayerUITests` (see
/// `project.yml`), so the two sides of a UI test share one definition of
/// every selector instead of the tests carrying a duplicate set of string
/// literals that can drift. That is why this file imports only `Foundation`
/// and refers to no app model.
///
/// Deliberately separate from the `.accessibilityLabel(...)` pass that
/// already covers this app: labels are user-facing, go through
/// `String(localized:)`/`Localizable.xcstrings`, and would break every
/// selector the moment a second language is added. Identifiers are invisible
/// to VoiceOver, so adding them alongside a label changes nothing about what
/// gets spoken.
///
/// Four rules when adding to this list:
///
/// - Add an identifier in the same change that applies it to a view. A
///   constant nothing uses reads as an available selector and silently
///   never resolves; this list is deliberately kept to what exists.
/// - Attach the identifier to the *same* element the label pass targeted.
///   Several composite cards here use `.accessibilityElement(children:
///   .ignore)` and collapse to a single element by design; putting an
///   identifier on a child of one of those makes it unreachable, and
///   wrapping a `Button` in a new container to hold the identifier strips
///   its `Button` trait — apply `.accessibilityIdentifier(...)` directly to
///   the `Button`, never to a `Group`/`ZStack` placed around it.
/// - Identify controls, not screen roots. There is deliberately no
///   `root` identifier for any screen here. An identifier on a container
///   sometimes lands on that container alone and sometimes propagates down
///   onto every descendant, *overwriting* the identifiers they set
///   themselves — measured both ways in this app: on `PlayerView` it left 22
///   elements all reporting `player.root` with every control unreachable,
///   and on `HomeView` it silently swallowed `OfflineStateView`'s own
///   identifier in the offline branch while leaving the loaded branch
///   intact. Which behaviour you get depends on the surrounding view tree,
///   so a screen is identified by a control only it has (its primary
///   button, one of its cards), never by a wrapper.
/// - Prefer an identifier over a title for anything ambiguous. "Advanced" is
///   the nav title *and* link text of two different screens
///   (`AdvancedPlaybackSettingsView`, `DownloadsQualityLadderView`), and
///   "Downloads" is simultaneously a tab, a Profile section, a settings
///   screen and a settings row.
enum A11yID {
    enum ServerSetup {
        static let addressField = "serverSetup.addressField"
        static let httpsToggle = "serverSetup.httpsToggle"
        static let connectButton = "serverSetup.connectButton"
        static let errorMessage = "serverSetup.errorMessage"
    }

    enum Login {
        static let usernameField = "login.usernameField"
        static let passwordField = "login.passwordField"
        static let signInButton = "login.signInButton"
        static let changeServerButton = "login.changeServerButton"
        static let errorMessage = "login.errorMessage"
    }

    /// iPad only, in practice. SwiftUI's floating tab bar keeps an
    /// identifier set inside `.tabItem`; iPhone converts the same item into
    /// a UIKit `UITabBarItem`, which drops it. `DionysusPlayerUITests`'
    /// `TabBar` screen object falls back to tab order there — see its note.
    enum Tabs {
        static let home = "tab.home"
        static let search = "tab.search"
        static let downloads = "tab.downloads"
        static let profile = "tab.profile"
    }

    enum Home {
        static let heroCarousel = "home.heroCarousel"
        static let refreshButton = "home.refreshButton"
        static let libraryRail = "home.libraryRail"

        /// A rail header's "See All", keyed by where it goes —
        /// `CollectionQuery.identifierKey`.
        ///
        /// Not keyed by the rail itself: `MediaCollectionRail.id` is a fresh
        /// `UUID` per launch (deliberately — see its doc comment), so it is
        /// unaddressable from a test, and the rail's title is generated,
        /// localized display text. The destination query is the only stable
        /// identity a rail actually has.
        ///
        /// Takes the key rather than the query so this file stays free of
        /// app-model dependencies — it is compiled into the UI test target
        /// as well, which does not link the app module. The query overload
        /// lives in `CollectionQuery+AccessibilityIdentifier.swift`.
        static func seeAll(_ queryKey: String) -> String { "home.seeAll." + queryKey }
    }

    enum Collection {
        static let grid = "collection.grid"
        static let sortMenu = "collection.sortMenu"
        static let randomButton = "collection.randomButton"
        static let resetFiltersButton = "collection.resetFiltersButton"
        static let emptyState = "collection.emptyState"
        /// Distinct from `emptyState`: this is "the library has items but
        /// the active filters match none of them", which
        /// `CollectionGridViewModel`'s cascading facets are supposed to make
        /// unreachable through the UI.
        static let noFilterMatches = "collection.noFilterMatches"

        /// `facet` is a `CollectionFilterFacet` raw value, not a label.
        static func filterPill(_ facet: String) -> String { "collection.filter.\(facet)" }
    }

    enum Search {
        // Deliberately no `results`/`history` container identifiers: an
        // identifier applied to either list is claimed by the enclosing
        // `root` scroll view and never reaches a real element. Assert on the
        // result cards instead, which carry `A11yID.Media.card(_:)`.
        static let emptyState = "search.emptyState"
    }

    enum AssetDetail {
        static let playButton = "assetDetail.playButton"
        static let restartButton = "assetDetail.restartButton"
        static let favoriteButton = "assetDetail.favoriteButton"
        static let watchedButton = "assetDetail.watchedButton"
        static let unsupportedAudioMessage = "assetDetail.unsupportedAudioMessage"
    }

    enum Player {
        static let closeButton = "player.closeButton"
        static let playPauseButton = "player.playPauseButton"
        static let skipForwardButton = "player.skipForwardButton"
        static let skipBackwardButton = "player.skipBackwardButton"
        static let scrubber = "player.scrubber"
        static let elapsedLabel = "player.elapsedLabel"
        static let remainingLabel = "player.remainingLabel"
        static let tracksButton = "player.tracksButton"
        static let chaptersButton = "player.chaptersButton"
        static let chapterPicker = "player.chapterPicker"
        static let rotationLockButton = "player.rotationLockButton"
        static let pictureInPictureButton = "player.pictureInPictureButton"
        static let statsButton = "player.statsButton"
    }

    enum Downloads {
        static let list = "downloads.list"
        static let emptyState = "downloads.emptyState"
        static let selectButton = "downloads.selectButton"
        static let deleteSelectedButton = "downloads.deleteSelectedButton"
    }

    enum Profile {
        static let accountCard = "profile.accountCard"
        static let accountSheet = "profile.accountSheet"
        static let signOutButton = "profile.signOutButton"
        static let changeServerButton = "profile.changeServerButton"
        static let advancedPlaybackLink = "profile.advancedPlaybackLink"
        static let downloadsSettingsLink = "profile.downloadsSettingsLink"
        static let qualityLadderLink = "profile.qualityLadderLink"
        static let licenseLink = "profile.licenseLink"
        static let privacyPolicyLink = "profile.privacyPolicyLink"
    }

    /// Shared across every surface that renders a media tile, so a test can
    /// address one specific item wherever it appears.
    enum Media {
        static func card(_ itemID: String) -> String { "media.card.\(itemID)" }
    }

    /// Loading / error / offline placeholders, which several screens share.
    enum State {
        static let loading = "state.loading"
        static let error = "state.error"
        static let offline = "state.offline"
        static let retryButton = "state.retryButton"
    }
}
