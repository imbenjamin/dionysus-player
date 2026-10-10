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
    enum Welcome {
        static let getStartedButton = "welcome.getStartedButton"
        static let jellyfinLink = "welcome.jellyfinLink"
    }

    enum ServerSetup {
        /// Opens the address sheet, which holds `addressField`,
        /// `httpsToggle` and `connectButton`.
        static let manualEntryButton = "serverSetup.manualEntryButton"
        static let addressSheetCancelButton = "serverSetup.addressSheet.cancel"
        static let addressField = "serverSetup.addressField"
        static let httpsToggle = "serverSetup.httpsToggle"
        static let connectButton = "serverSetup.connectButton"
        static let errorMessage = "serverSetup.errorMessage"
        /// "Scan Again", or "Try Again" after a scan found nothing. There is
        /// no button while a scan runs: one starts on arrival.
        static let scanButton = "serverSetup.scanButton"
        static let scanStatus = "serverSetup.scanStatus"
        /// Under the servers found so far, while the scan is still running.
        static let scanningIndicator = "serverSetup.scanningIndicator"
        static func discoveredServer(_ id: String) -> String { "serverSetup.discoveredServer.\(id)" }
        static let insecureFallbackConfirmButton = "serverSetup.insecureFallback.confirm"
        static let insecureFallbackCancelButton = "serverSetup.insecureFallback.cancel"
        static let httpPortConfirmButton = "serverSetup.httpPort.confirm"
        static let httpPortCancelButton = "serverSetup.httpPort.cancel"
    }

    enum Login {
        /// A user from the server's public list, keyed by user id.
        static func userTile(_ userID: String) -> String { "login.userTile.\(userID)" }
        /// The last tile: manual sign-in and Quick Connect, in a sheet.
        static let otherUserButton = "login.otherUserButton"
        static let otherUserCancelButton = "login.otherUser.cancel"
        /// In the "Other" sheet, or on the screen itself when the server lists
        /// no users.
        static let usernameField = "login.usernameField"
        /// Wherever a password is asked for: under a chosen user (a panel on a
        /// phone, a popover on iPad), in the "Other" sheet, or the fallback form.
        static let passwordField = "login.passwordField"
        static let signInButton = "login.signInButton"
        /// The server's own login disclaimer, when it has one.
        static let disclaimer = "login.disclaimer"
        static let changeServerButton = "login.changeServerButton"
        static let errorMessage = "login.errorMessage"
        /// Present only when the server reports Quick Connect enabled; in the
        /// "Other" sheet, or on the fallback form.
        static let quickConnectButton = "login.quickConnectButton"
    }

    enum QuickConnect {
        static let code = "quickConnect.code"
        static let cancelButton = "quickConnect.cancelButton"
        static let newCodeButton = "quickConnect.newCodeButton"
        static let errorMessage = "quickConnect.errorMessage"
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

        /// A rail header's link to its full collection (the title and its
        /// chevron, once a separate "See All"; the name is kept so existing
        /// tests still address it), keyed by where it goes —
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
        /// The About panel's synopsis line: the synopsis, or "No synopsis
        /// available." without one. The line is always there when the panel
        /// is, so its absence on a playlist without a description proves the
        /// whole panel was left out (see `PlaylistDetailView`).
        static let synopsis = "assetDetail.synopsis"
        /// `SeasonEpisodeList`'s empty state, for a season holding no episodes.
        static let noEpisodesMessage = "assetDetail.noEpisodesMessage"

        /// A show's episode list row — its title/overview half (`onSelect`,
        /// which switches the page's own content to that episode in place,
        /// not a push), keyed by the episode's item id like every other
        /// media tile. The thumbnail half (`onPlay`) carries no identifier
        /// of its own; nothing here drives it directly.
        static func episodeRow(_ episodeID: String) -> String { "assetDetail.episodeRow.\(episodeID)" }

        /// `DownloadButton`'s own tap target — one identifier covers every
        /// one of its states (idle/resolving/downloading/downloaded), the
        /// same "the action stays put, only the label changes" shape
        /// `playButton` above already uses for Play/Resume.
        static let downloadButton = "assetDetail.downloadButton"

        /// `AssetActionsButton`'s delete affordance — present only when the
        /// server says this user may delete this item (`MediaItem.canDelete`),
        /// so a UI test asserting its *absence* is asserting the permission
        /// gate, not just a missing view. It is always inside `moreButton`'s
        /// overflow: a flat row on a movie, a Show/Season/Episode submenu on a
        /// show page.
        static let deleteButton = "assetDetail.deleteButton"

        /// The destructive confirm action inside the deletion dialog. Needed
        /// separately from `deleteButton` because the dialog's own button
        /// would otherwise be matched by title alone — and, per
        /// `Screens.swift`, an `app.buttons[...]` subscript matches labels as
        /// well as identifiers, so the row that raised the dialog collides
        /// with the dialog's own button without one.
        static let deleteConfirmButton = "assetDetail.deleteConfirmButton"

        /// The dialog's "also remove the downloaded copy" action, offered
        /// only when a local download of the target actually exists.
        static let deleteWithDownloadButton = "assetDetail.deleteWithDownloadButton"

        /// `AssetActionsButton`'s overflow — always drawn, so the control never
        /// changes kind once the server's delete verdict arrives (see that
        /// type's "Which control gets drawn"). Holds Add to Playlist, and
        /// Delete when permitted.
        static let moreButton = "assetDetail.moreButton"

        /// The "Add to Playlist" affordance inside `moreButton`'s overflow: a
        /// flat row on a movie, a Show/Season/Episode submenu on a show page.
        /// One identifier covers both, the same rule `deleteButton` above
        /// follows.
        static let addToPlaylistButton = "assetDetail.addToPlaylistButton"
    }

    /// `AddToPlaylistSheet` — the destination picker, and its pushed
    /// "New Playlist" form.
    enum AddToPlaylist {
        /// One existing, editable playlist's row, keyed by the playlist's own
        /// item id. Rows are named by server-supplied playlist names, which a
        /// test can't select on.
        static func playlistRow(_ playlistID: String) -> String { "addToPlaylist.row.\(playlistID)" }

        /// Always present, including when the user can edit no existing
        /// playlist at all — creating one needs no server permission.
        static let newPlaylistButton = "addToPlaylist.newPlaylistButton"

        /// The footer shown in place of the playlist list when this user can
        /// edit none of them. Its presence is how a test asserts the
        /// `canEdit` filter actually filtered.
        static let emptyState = "addToPlaylist.emptyState"

        /// The confirmation dialog's destructive-free "Add" action, raised
        /// only for a show/season target (see `AddToPlaylistViewModel
        /// .requiresConfirmation`). Needed separately from `playlistRow(_:)`
        /// because an `app.buttons[...]` subscript matches labels as well as
        /// identifiers — see `Screens.swift`.
        static let addConfirmButton = "addToPlaylist.addConfirmButton"

        /// Both confirmations' Cancel actions carry identifiers, unlike the
        /// deletion dialog's — that one is toolbar-anchored, so iOS renders
        /// it as a popover and drops Cancel entirely. These are `.alert`s
        /// raised from inside a sheet precisely *because* the dialog form
        /// dropped Cancel there too, so their Cancel is a real element worth
        /// asserting on.
        static let addCancelButton = "addToPlaylist.addCancelButton"
        static let createCancelButton = "addToPlaylist.createCancelButton"

        static let nameField = "addToPlaylist.nameField"
        static let visibilityToggle = "addToPlaylist.visibilityToggle"
        /// The create form's toolbar action, which raises the confirmation.
        static let createButton = "addToPlaylist.createButton"
        /// The confirmation dialog's own action, distinct from
        /// `createButton` for the same label-collision reason as
        /// `addConfirmButton`.
        static let createConfirmButton = "addToPlaylist.createConfirmButton"
    }

    enum Playlist {
        /// A playlist member row itself — what a UI test long-presses to
        /// reveal `removeMenuItem(_:)`'s context menu, since there's no
        /// reliable way to select one specific row among several by
        /// accessibility label (localized, and shared across rows of the
        /// same kind of content). Keyed the same way as
        /// `removeMenuItem(_:)`.
        static func row(_ playlistItemID: String) -> String { "playlist.row.\(playlistItemID)" }

        /// A playlist member row's `.contextMenu` "Remove from Playlist"
        /// action — the *only* removal path (see `PlaylistItemList
        /// .onRemove`'s doc comment for why a hand-rolled swipe gesture
        /// was tried and reverted), present only when the server says this
        /// user may edit this playlist (`AssetDetailViewModel
        /// .canEditPlaylist`), same "absence gates the permission check"
        /// shape `AssetDetail.deleteButton` uses. Keyed by
        /// `MediaItem.playlistItemID`, not the item's own `id` — the same
        /// item can appear in a playlist more than once.
        static func removeMenuItem(_ playlistItemID: String) -> String { "playlist.removeMenuItem.\(playlistItemID)" }
    }

    enum Player {
        /// The composited libass bitmap, present only while an authored
        /// ASS/SSA track is being rendered by it. Its accessibility LABEL
        /// carries the cue text, which is the only way a test — or VoiceOver —
        /// can read a subtitle that is a picture rather than a `Text`.
        static let styledSubtitle = "player.styledSubtitle"

        /// A cue rendered by the app's OWN overlay rather than libass — every
        /// SubRip/WebVTT track, and an ASS one with Subtitle Styling off.
        /// Several can be on screen at once (a sign alongside dialogue), so a
        /// query for this resolves to more than one element by design; match
        /// the first.
        static let plainSubtitle = "player.plainSubtitle"
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
        /// `PlaybackStatsOverlay`'s "1/3" page counter.
        static let statsPageIndicator = "player.stats.pageIndicator"
        /// A stats row's VALUE text, keyed by the row's English label ("Codec",
        /// "Sampling"), or its own key where two sections share a label ("Audio
        /// Decoder"). Every page's rows resolve, not just the showing page's:
        /// they all stay mounted, so read `statsPageIndicator` for the page.
        static func statsValue(_ rowLabel: String) -> String { "player.stats.value.\(rowLabel)" }

        /// The track picker's root page — its two "Audio"/"Subtitles"
        /// navigation rows, keyed by `TrackPickerLeaf`'s raw kind ("audio"/
        /// "subtitle") rather than by title, which is `String(localized:)`.
        static func trackNavigationRow(_ kind: String) -> String { "player.trackPicker.navRow.\(kind)" }

        /// A leaf page's own selectable rows — audio tracks, subtitle
        /// tracks, and the subtitle leaf's own "Off" row — keyed by
        /// `PlaybackTrack.id` (stable per track for a given load) and the
        /// same kind string `trackNavigationRow(_:)` uses, since a
        /// selection row's title/metadata are display text, not identity.
        static func trackOption(_ kind: String, _ id: Int) -> String { "player.trackPicker.option.\(kind).\(id)" }

        /// The subtitle leaf's "Off" row, which has no `PlaybackTrack` of
        /// its own to key `trackOption(_:_:)` off.
        static let subtitleOffOption = "player.trackPicker.option.subtitle.off"

        /// A `ChapterPickerOverlay` row, keyed by `Chapter.index` — stable
        /// across the online/offline model swap `Chapter.id`'s own doc
        /// comment describes, and simpler than that composite string id for
        /// a test that just wants "the second chapter".
        static func chapterOption(_ index: Int) -> String { "player.chapterPicker.option.\(index)" }
    }

    enum Downloads {
        static let list = "downloads.list"
        static let emptyState = "downloads.emptyState"
        /// One row of the landing list or grid, keyed by `DownloadsRow.id`
        /// (`standalone-<itemID>` or `show-<seriesID>`).
        static func row(_ rowID: String) -> String { "downloads.row.\(rowID)" }
        /// The shared `DownloadsSelectionToolbar`'s controls, the same on the
        /// Downloads tab and the downloaded show and season pages.
        static let selectButton = "downloads.selectButton"
        static let cancelSelectionButton = "downloads.cancelSelectionButton"
        static let deleteSelectedButton = "downloads.deleteSelectedButton"
        static let selectAllButton = "downloads.selectAllButton"
    }

    enum Profile {
        static let accountCard = "profile.accountCard"
        static let accountSheet = "profile.accountSheet"
        static let signOutButton = "profile.signOutButton"
        static let changeServerButton = "profile.changeServerButton"
        /// Present only when the server reports Quick Connect enabled.
        static let quickConnectRow = "profile.quickConnectRow"
        static let advancedPlaybackLink = "profile.advancedPlaybackLink"
        static let styledSubtitlesToggle = "profile.styledSubtitlesToggle"
        static let downloadsSettingsLink = "profile.downloadsSettingsLink"
        static let qualityLadderLink = "profile.qualityLadderLink"
        static let licenseLink = "profile.licenseLink"
        static let privacyPolicyLink = "profile.privacyPolicyLink"
    }

    /// Shared across every surface that renders a media tile, so a test can
    /// address one specific item wherever it appears.
    /// Approving another device's code, pushed from the Account screen.
    enum QuickConnectApproval {
        static let codeField = "quickConnectApproval.codeField"
        static let authorizeButton = "quickConnectApproval.authorizeButton"
        static let errorMessage = "quickConnectApproval.errorMessage"
        static let successMessage = "quickConnectApproval.successMessage"
        static let doneButton = "quickConnectApproval.doneButton"
    }

    enum Media {
        static func card(_ itemID: String) -> String { "media.card.\(itemID)" }

        /// A test-only marker (see `LogoImageView.onFallbackVisibilityChange`)
        /// present in the tree exactly while a hero logo's text fallback is
        /// showing — `BackdropLogoOverlay` and `PlayerControlsOverlay`'s
        /// title row both wrap their real logo/fallback content in an
        /// accessibility-hidden or `.ignore`-collapsed layer (VoiceOver
        /// fixes documented on those types), so this is the only element a
        /// UI test can actually query to observe that timing.
        static let heroLogoFallbackVisible = "media.heroLogoFallbackVisible"
    }

    /// `ToastHost`'s transient confirmation. One identifier for the whole
    /// capsule, which collapses to a single accessibility element by design
    /// — a test reads its *label* for the message, since the message itself
    /// is localized copy.
    enum Toast {
        static let message = "toast.message"
    }

    /// Loading / error / offline placeholders, which several screens share.
    enum State {
        static let loading = "state.loading"
        static let error = "state.error"
        static let offline = "state.offline"
        static let retryButton = "state.retryButton"
    }

    /// The Apple TV app's identifiers. Never on a screen-root container (see the
    /// file's header); each sits on a concrete element inside the screen.
    enum TV {
        enum Onboarding {
            static let findServerTitle = "tv.onboarding.findServer.title"
            static let welcomeTitle = "tv.onboarding.welcome.title"
            static let getStarted = "tv.onboarding.welcome.getStarted"
            static let enterAddress = "tv.onboarding.findServer.enterAddress"
            static let addressField = "tv.onboarding.findServer.addressField"
            static let rescan = "tv.onboarding.findServer.rescan"
            static func serverRow(_ id: String) -> String { "tv.onboarding.server.\(id)" }
            static let whosWatchingTitle = "tv.onboarding.whosWatching.title"
            static func user(_ id: String) -> String { "tv.onboarding.user.\(id)" }
            static let otherUser = "tv.onboarding.user.other"
            /// A user already signed in on this Apple TV, in place of `user(_:)`.
            static func rememberedUser(_ id: String) -> String { "tv.onboarding.rememberedUser.\(id)" }
            static let forgetAccount = "tv.onboarding.forgetAccount"
            static let quickConnectCode = "tv.onboarding.quickConnect.code"
            static let usePassword = "tv.onboarding.quickConnect.usePassword"
            static let passwordField = "tv.onboarding.password.field"
            static let changeServer = "tv.onboarding.whosWatching.changeServer"
        }
        enum Main {
            static func tile(_ itemID: String) -> String { "tv.main.tile.\(itemID)" }
            static let heroPlay = "tv.main.hero.play"
            static let heroInfo = "tv.main.hero.info"
            static let heroTitle = "tv.main.hero.title"
            static let heroDots = "tv.main.hero.dots"
            static func seeAll(_ title: String) -> String { "tv.main.seeAll.\(title)" }
            /// A rail as one container named for its heading (not a screen
            /// root, so its tiles keep their identifiers).
            static func railGroup(_ title: String) -> String { "tv.main.railGroup.\(title)" }
            static func rail(_ title: String) -> String { "tv.main.rail.\(title)" }
            static func library(_ libraryID: String) -> String { "tv.main.library.\(libraryID)" }
            static let retry = "tv.main.retry"
        }
        enum Search {
            static func result(_ itemID: String) -> String { "tv.search.result.\(itemID)" }
            static func section(_ id: String) -> String { "tv.search.section.\(id)" }
            static func recent(_ itemID: String) -> String { "tv.search.recent.\(itemID)" }
            static func recentSection(_ id: String) -> String { "tv.search.recentSection.\(id)" }
            static let clearRecent = "tv.search.recent.clear"
            static let noResults = "tv.search.noResults"
            static let emptyHistory = "tv.search.emptyHistory"
        }
        enum Library {
            static let count = "tv.library.count"
            static let sort = "tv.library.sort"
            static func filter(_ facet: String) -> String { "tv.library.filter.\(facet)" }
            static let resetFilters = "tv.library.resetFilters"
            /// A choice in an open pill's list: "all", or the option's index.
            static func option(_ pill: String, _ option: String) -> String { "tv.library.option.\(pill).\(option)" }
            static let retry = "tv.library.retry"
            static func title(_ libraryID: String) -> String { "tv.library.title.\(libraryID)" }
            static func tile(_ itemID: String) -> String { "tv.library.tile.\(itemID)" }
        }
        enum Detail {
            static let title = "tv.detail.title"
            static let play = "tv.detail.play"
            static let restart = "tv.detail.restart"
            static let watched = "tv.detail.watched"
            static let favorite = "tv.detail.favorite"
            static let overview = "tv.detail.overview"
            static let retry = "tv.detail.retry"
            static func similar(_ itemID: String) -> String { "tv.detail.similar.\(itemID)" }
            static func cast(_ memberID: String) -> String { "tv.detail.cast.\(memberID)" }
            static let details = "tv.detail.details"
            static let fullDetailsTitle = "tv.detail.fullDetails.title"
            /// Which episode a show page's Details describe.
            static let detailsSubject = "tv.detail.details.subject"
            static func season(_ seasonID: String) -> String { "tv.detail.season.\(seasonID)" }
            static func episode(_ episodeID: String) -> String { "tv.detail.episode.\(episodeID)" }
            static let noEpisodes = "tv.detail.noEpisodes"
            /// A box set's movie or a playlist's entry.
            static func member(_ id: String) -> String { "tv.detail.member.\(id)" }
            static let emptyMessage = "tv.detail.empty"
            static let loading = "tv.detail.loading"
            /// Each format badge in the header ("4K", "HDR10"…).
            static let badge = "tv.detail.badge"
            /// The poster or still beside the title, for a title with no backdrop.
            static let headerArt = "tv.detail.headerArt"
        }
        enum Profile {
            static let name = "tv.profile.name"
            static let server = "tv.profile.server"
            static let switchUser = "tv.profile.switchUser"
            static let changeServer = "tv.profile.changeServer"
            static let changeServerConfirm = "tv.profile.changeServer.confirm"
            static let signOutConfirm = "tv.profile.signOut.confirm"
            static let followsAppleTVUsers = "tv.profile.followsAppleTVUsers"
            static let selectsUserEveryRelaunch = "tv.profile.selectsUserEveryRelaunch"
            static let approveQuickConnect = "tv.profile.approveQuickConnect"
            static let signOut = "tv.profile.signOut"
            static let autoCarousel = "tv.profile.autoCarousel"
            static let nextUpCountdown = "tv.profile.nextUpCountdown"
            static let chaptersInScrubber = "tv.profile.chaptersInScrubber"
            static let advanced = "tv.profile.advanced"
            static let license = "tv.profile.license"
            static let privacyPolicy = "tv.profile.privacyPolicy"
            static let version = "tv.profile.version"
            static let streamingMode = "tv.profile.advanced.streamingMode"
            static let maxBitrate = "tv.profile.advanced.maxBitrate"
            static let subtitleStyling = "tv.profile.advanced.subtitleStyling"
            static let statsButton = "tv.profile.advanced.statsButton"
            static let quickConnectCode = "tv.profile.quickConnect.code"
            static let quickConnectAuthorize = "tv.profile.quickConnect.authorize"
            static let quickConnectMessage = "tv.profile.quickConnect.message"
            static let textPage = "tv.profile.textPage"
            /// A choice on a setting's picker page, by the option's id
            /// (`StreamDecisionMode.rawValue`, a countdown's seconds…).
            static func option(_ id: String) -> String { "tv.profile.option.\(id)" }
        }
        /// The custom sidebar's rows (collapsed rail and open panel alike).
        enum Sidebar {
            /// The rail as one container, named for VoiceOver. Not a screen
            /// root, so its rows keep their own identifiers.
            static let container = "tv.sidebar"
            static let profile = "tv.sidebar.profile"
            static let home = "tv.sidebar.home"
            static let search = "tv.sidebar.search"
            static let librariesGroup = "tv.sidebar.libraries"
            static func library(_ libraryID: String) -> String { "tv.sidebar.library.\(libraryID)" }
        }
        enum Player {
            static let transport = "tv.player.transport"
            static let titleBlock = "tv.player.title"
            static let elapsed = "tv.player.elapsed"
            static let remaining = "tv.player.remaining"
            static let formatLabel = "tv.player.format"
            static let scrubPreview = "tv.player.scrubPreview"
            static let bufferedRange = "tv.player.buffered"
            static let scanIndicator = "tv.player.scan"
            static let actionFlash = "tv.player.flash"
            static let skipButton = "tv.player.skip"
            static let nextUpCard = "tv.player.nextUp"
            static let nextUpPlayNow = "tv.player.nextUp.playNow"
            static let nextUpClose = "tv.player.nextUp.close"
            /// Test-only: a 1pt element whose label is `TVPlayerFocusID`'s
            /// id for what has focus, since the player doesn't use the focus
            /// engine XCUITest's `hasFocus` reads.
            static let focus = "tv.player.focus"
            static func icon(_ id: String) -> String { "tv.player.icon.\(id)" }
            /// The accessible transport's own buttons: back, playPause, forward, info.
            static func control(_ id: String) -> String { "tv.player.control.\(id)" }
            /// The scrubber as one adjustable element (accessible transport).
            static let scrubber = "tv.player.scrubber"
            /// The accessible transport's hidden state: one invisible
            /// button that brings the controls back.
            static let showControls = "tv.player.showControls"
            static let panel = "tv.player.panel"
            static let restart = "tv.player.restart"
            static let infoArt = "tv.player.infoArt"
            static func panelTab(_ id: String) -> String { "tv.player.tab.\(id)" }
            static func panelRow(_ tab: String, _ index: Int) -> String { "tv.player.row.\(tab).\(index)" }
            static let statsPanel = "tv.player.stats"
            /// A row: labelled with its name, its value as the accessibility
            /// value. Keyed by `PlaybackStatsReport.Row.id`.
            static func statsValue(_ id: String) -> String { "tv.player.stats.\(id)" }
        }
    }
}
