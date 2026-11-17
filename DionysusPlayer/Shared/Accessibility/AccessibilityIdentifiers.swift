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

    /// iPad, in practice, and the iPhone Duo's side bar (its tabs are found
    /// through `prefix`). SwiftUI's floating tab bar keeps an
    /// identifier set inside `.tabItem`; iPhone converts the same item into
    /// a UIKit `UITabBarItem`, which drops it. `DionysusPlayerUITests`'
    /// `TabBar` screen object falls back to tab order there — see its note.
    enum Tabs {
        /// What every tab's identifier starts with, so a UI test can tell the
        /// tabs from other buttons in the same bar (the iPhone Duo's side bar).
        static let prefix = "tab."
        static let home = "tab.home"
        static let search = "tab.search"
        static let downloads = "tab.downloads"
        static let profile = "tab.profile"
    }

    enum Home {
        static let heroCarousel = "home.heroCarousel"
        static let refreshButton = "home.refreshButton"
        /// The hero's Previous/Next buttons, shown when the carousel doesn't
        /// advance by itself (auto-advance off, or VoiceOver running).
        static let heroPrevious = "home.hero.previous"
        static let heroNext = "home.hero.next"
        static let libraryRail = "home.libraryRail"
        /// Home's "Nothing here yet." state: loaded, and the server had
        /// nothing to show. Not `State.error`, which a failed load shows too.
        static let emptyState = "home.emptyState"

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
        /// The poster page of an iPhone Duo's book spread
        /// (`DetailBookSpread`), shown instead of the hero.
        static let bookSpreadPoster = "assetDetail.bookSpreadPoster"
        static let restartButton = "assetDetail.restartButton"
        static let favoriteButton = "assetDetail.favoriteButton"
        static let watchedButton = "assetDetail.watchedButton"
        static let unsupportedAudioMessage = "assetDetail.unsupportedAudioMessage"
        /// The item is gone from the server (`AssetDetailViewModel.LoadState.notFound`).
        static let notFoundMessage = "assetDetail.notFoundMessage"
        /// The About panel's synopsis line: the synopsis, or "No synopsis
        /// available." without one. The line is always there when the panel
        /// is, so its absence on a playlist without a description proves the
        /// whole panel was left out (see `PlaylistDetailView`).
        static let synopsis = "assetDetail.synopsis"
        /// `DetailTabsView`'s segmented About / Cast & Crew / Details picker.
        static let tabPicker = "assetDetail.tabPicker"
        /// One of `tabPicker`'s segments: `about`, `cast` or `details`.
        static func tab(_ name: String) -> String { "assetDetail.tab.\(name)" }
        /// A Cast & Crew card, by the person's id.
        static func castMember(_ personID: String) -> String { "assetDetail.castMember.\(personID)" }
        /// The Details tab's Container and Video Codec values.
        static let detailsContainer = "assetDetail.details.container"
        static let detailsVideoCodec = "assetDetail.details.videoCodec"
        /// `SeasonEpisodeList`'s empty state, for a season holding no episodes.
        static let noEpisodesMessage = "assetDetail.noEpisodesMessage"

        /// A show's episode list row — its title/overview half (`onSelect`,
        /// which switches the page's own content to that episode in place,
        /// not a push), keyed by the episode's item id like every other
        /// media tile. The thumbnail half (`onPlay`) is `episodePlayButton`.
        static func episodeRow(_ episodeID: String) -> String { "assetDetail.episodeRow.\(episodeID)" }
        /// A show's episode row's thumbnail, which plays that episode
        /// (asking which version first when it has several, #289).
        static func episodePlayButton(_ episodeID: String) -> String { "assetDetail.episodePlayButton.\(episodeID)" }

        /// The page's own `DownloadButton` (its `.prominent` style) — one identifier covers every
        /// one of its states (idle/resolving/downloading/downloaded), the
        /// same "the action stays put, only the label changes" shape
        /// `playButton` above already uses for Play/Resume.
        static let downloadButton = "assetDetail.downloadButton"

        /// A row's own `DownloadButton` (an episode, collection or playlist
        /// row), keyed by the row's item id. Separate from `downloadButton`, which
        /// on a wide page matched the page's button and every row's at once.
        static func rowDownloadButton(_ itemID: String) -> String { "assetDetail.rowDownloadButton.\(itemID)" }

        /// `SeasonEpisodeList`'s season menu (shown for a show with more than
        /// one season), and one of its options, keyed by the season's item id.
        static let seasonPicker = "assetDetail.seasonPicker"
        static func seasonOption(_ seasonID: String) -> String { "assetDetail.seasonOption.\(seasonID)" }

        /// `SeasonDownloadButton`, which downloads every episode of the season
        /// on show, in every one of its states, like `downloadButton`.
        static let seasonDownloadButton = "assetDetail.seasonDownloadButton"

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

        /// A playlist member row's thumbnail, which plays it (`row(_:)` is the
        /// text beside it, which opens the member's page). Keyed like `row(_:)`.
        static func playButton(_ playlistItemID: String) -> String { "playlist.playButton.\(playlistItemID)" }

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
        /// SubRip/WebVTT track, and an ASS one with ASS/SSA Subtitles off.
        /// Several can be on screen at once (a sign alongside dialogue), so a
        /// query for this resolves to more than one element by design; match
        /// the first.
        static let plainSubtitle = "player.plainSubtitle"
        /// A bitmap cue (PGS, VobSub, DVB) on the app's own overlay. In the
        /// accessibility tree under the UI-test harness only: VoiceOver has
        /// nothing to read in it.
        static let imageSubtitle = "player.imageSubtitle"
        /// "Reconnecting…", under the spinner while the source is retried.
        static let reconnecting = "player.reconnecting"
        /// The placeholder covering the video while Picture in Picture has it.
        static let pictureInPictureOverlay = "player.pictureInPictureOverlay"
        /// The picture rect `SubtitleOverlayView` places cues against, under
        /// the UI-test harness only.
        static let subtitlePicture = "player.subtitlePicture"
        static let closeButton = "player.closeButton"
        static let playPauseButton = "player.playPauseButton"
        static let skipForwardButton = "player.skipForwardButton"
        static let skipBackwardButton = "player.skipBackwardButton"
        /// `SkipSegmentOverlay`'s Skip Intro/Recap/Credits button.
        static let skipSegmentButton = "player.skipSegmentButton"
        /// The VoiceOver-only button dismissing it, beside it.
        static let skipSegmentDismissButton = "player.skipSegmentDismissButton"
        /// The VoiceOver-only Show/Hide Player Controls button, on the leading
        /// edge, mounted whatever `showControls` says.
        static let voiceOverControlsButton = "player.voiceOverControlsButton"
        /// `NextUpOverlay`'s card (a container, so its buttons keep their
        /// own identifiers) and its two buttons.
        static let nextUpCard = "player.nextUp"
        static let nextUpPlayNow = "player.nextUp.playNow"
        static let nextUpCancel = "player.nextUp.cancel"
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
        /// The Audio page's offset section (`PlayerControlsOverlay.audioOffsetSection`).
        static let audioOffsetHeading = "player.audioOffset.heading"
        /// The Audio Offset page's back row, to the Audio page.
        static let audioOffsetBack = "player.audioOffset.back"
        static let audioOffsetValue = "player.audioOffset.value"
        static let audioOffsetDecrease = "player.audioOffset.decrease"
        static let audioOffsetIncrease = "player.audioOffset.increase"
        /// `thisTitle` or `allTitles`.
        static func audioOffsetScope(_ scope: String) -> String { "player.audioOffset.scope.\(scope)" }
        static let audioOffsetReset = "player.audioOffset.reset"

        /// A `ChapterPickerOverlay` row, keyed by `Chapter.index` — stable
        /// across the online/offline model swap `Chapter.id`'s own doc
        /// comment describes, and simpler than that composite string id for
        /// a test that just wants "the second chapter".
        static func chapterOption(_ index: Int) -> String { "player.chapterPicker.option.\(index)" }

        /// The top row's moon, opening the Night panel (`NightModePanel`).
        /// The panel has no container identifier (see this enum's rules);
        /// `nightToggle` stands in for it. The dimming layer has none either:
        /// it's hidden from accessibility, so journeys read Playback Stats'
        /// "Night Mode" row.
        static let nightButton = "player.night.button"
        static let nightToggle = "player.night.toggle"
        static let nightAudio = "player.night.nightAudio"
        /// A level's value, or under VoiceOver the whole row as one
        /// adjustable element.
        static let nightVolume = "player.night.volume"
        static let nightBrightness = "player.night.brightness"
        /// A level's `[0%] [−] [+] [100%]` buttons: `volume` or `brightness`,
        /// then `min`, `decrease`, `increase` or `max`, e.g.
        /// `player.night.brightness.min`.
        static func nightControl(_ level: String, _ control: String) -> String { "player.night.\(level).\(control)" }
        static let nightScheduleSummary = "player.night.scheduleSummary"
    }

    /// Playback Stats rows read by journeys on both apps, with one identifier
    /// on iOS's overlay and the Apple TV's panel alike
    /// (`PlaybackStatsReport.Row.valueIdentifier`). Every other row keeps its
    /// platform's own `statsValue` scheme.
    enum PlaybackStats {
        /// The Video section's "Version" value: the label of the version
        /// playing, shown only for a title with more than one (#289).
        static let versionValue = "playbackStats.value.version"
    }

    /// The "Choose a Version" question (#289).
    enum Versions {
        /// One version's button, keyed by its `MediaVersion.id` (the
        /// `MediaSourceInfo.id`), so a test picks a version without reading
        /// its label, which may carry "(Last Played)".
        static func option(_ versionID: String) -> String { "versions.option.\(versionID)" }
        /// A season download's single question (every episode has the same
        /// versions): one option per label, keyed by its position in the
        /// list, since each episode's sources have ids of their own.
        static func bulkOption(_ index: Int) -> String { "versions.bulkOption.\(index)" }
        /// `BulkVersionChoiceSheet`'s row for one episode: its Version menu.
        static func bulkRowPicker(_ episodeID: String) -> String { "versions.bulkRow.\(episodeID)" }
        /// One version in a row's menu, by the episode and the version's
        /// `MediaVersion.id`.
        static func bulkRowOption(_ episodeID: String, _ versionID: String) -> String {
            "versions.bulkRow.\(episodeID).\(versionID)"
        }
        static let bulkDownloadButton = "versions.bulkDownloadButton"
        static let bulkCancelButton = "versions.bulkCancelButton"
    }

    enum Downloads {
        static let list = "downloads.list"
        static let emptyState = "downloads.emptyState"
        /// One row of the landing list or grid, keyed by `DownloadsRow.id`
        /// (`standalone-<itemID>` or `show-<seriesID>`).
        static func row(_ rowID: String) -> String { "downloads.row.\(rowID)" }
        /// The downloaded item page's Play (or Resume) button.
        static let playButton = "downloads.detail.playButton"
        /// A season row on a downloaded show's page (`DownloadedShowView`,
        /// when more than one season is downloaded), keyed by the season id.
        static func seasonRow(_ seasonID: String) -> String { "downloads.seasonRow.\(seasonID)" }
        /// An episode row or tile on a downloaded show's or season's page,
        /// keyed by the episode's item id.
        static func episodeRow(_ itemID: String) -> String { "downloads.episodeRow.\(itemID)" }
        /// The shared `DownloadsSelectionToolbar`'s controls, the same on the
        /// Downloads tab and the downloaded show and season pages.
        static let selectButton = "downloads.selectButton"
        static let cancelSelectionButton = "downloads.cancelSelectionButton"
        static let deleteSelectedButton = "downloads.deleteSelectedButton"
        static let selectAllButton = "downloads.selectAllButton"
        /// A downloaded title's About/Cast & Crew/Details segment:
        /// `about`, `cast` or `details`.
        static func tab(_ name: String) -> String { "downloads.detail.tab.\(name)" }
        /// The Details tab's Version value: which version was downloaded
        /// (#289), shown when the title had more than one.
        static let detailsVersionValue = "downloads.detail.versionValue"
    }

    enum Profile {
        static let accountCard = "profile.accountCard"
        /// The iPad sidebar's pane rows (`ProfileSettingsPane`). iPhone has
        /// no sidebar; its sections sit in one list.
        static let appearancePane = "profile.pane.appearance"
        static let playbackPane = "profile.pane.playback"
        static let downloadsPane = "profile.pane.downloads"
        static let aboutPane = "profile.pane.about"
        /// Playback → Audio Offset's stepper, and Reset to 0 ms beside it.
        static let audioOffsetStepper = "profile.audioOffset.stepper"
        static let audioOffsetReset = "profile.audioOffset.reset"
        /// Playback → Subtitle Style's picker.
        static let subtitleAppearance = "profile.subtitleAppearance"
        static let spatialAtmosToggle = "profile.spatialAudio.atmos.toggle"
        static let spatialAtmosLayout = "profile.spatialAudio.atmos.layout"
        static let spatialDTSXToggle = "profile.spatialAudio.dtsx.toggle"
        static let spatialDTSXLayout = "profile.spatialAudio.dtsx.layout"
        /// The section footer's Learn More button, and the sheet it opens:
        /// the page's text block (never the sheet's root) and its Done.
        static let spatialAudioLearnMore = "profile.spatialAudio.learnMore"
        static let spatialAudioHelp = "profile.spatialAudio.help"
        static let spatialAudioHelpDone = "profile.spatialAudio.help.done"
        static let accountSheet = "profile.accountSheet"
        static let signOutButton = "profile.signOutButton"
        static let changeServerButton = "profile.changeServerButton"
        /// Present only when the server reports Quick Connect enabled.
        static let quickConnectRow = "profile.quickConnectRow"
        static let advancedPlaybackLink = "profile.advancedPlaybackLink"
        /// Playback → Night Mode (`NightModeSettingsView`): its row, the
        /// switches, each level's value (under VoiceOver the whole row) and
        /// buttons (`nightControl("volume", "decrease")`), the schedule's
        /// switch and time pickers, and the note shown while both times are
        /// the same.
        static let nightLink = "profile.night.link"
        static let nightToggle = "profile.night.toggle"
        static let nightAudio = "profile.night.nightAudio"
        static let nightVolume = "profile.night.volume"
        static let nightBrightness = "profile.night.brightness"
        static func nightControl(_ level: String, _ control: String) -> String { "profile.night.\(level).\(control)" }
        static let nightSchedule = "profile.night.schedule"
        static let nightTurnOn = "profile.night.turnOn"
        static let nightTurnOff = "profile.night.turnOff"
        static let nightSameTimesNote = "profile.night.sameTimesNote"
        static let styledSubtitlesToggle = "profile.styledSubtitlesToggle"
        static let readAheadBufferStepper = "profile.readAheadBuffer.stepper"
        static let downloadsSettingsLink = "profile.downloadsSettingsLink"
        static let qualityLadderLink = "profile.qualityLadderLink"
        static let licenseLink = "profile.licenseLink"
        static let privacyPolicyLink = "profile.privacyPolicyLink"
    }

    /// Profile → Downloads (`DownloadsSettingsView`), and the quality ladder
    /// pushed from its Advanced link (`DownloadsQualityLadderView`).
    enum DownloadsSettings {
        static let resolutionPicker = "downloadsSettings.resolution"
        static let qualityPicker = "downloadsSettings.quality"
        static let simultaneousSlider = "downloadsSettings.simultaneous"
        static let wifiOnlyToggle = "downloadsSettings.wifiOnly"
        /// A ladder cell's Kbps field, and the reset button shown beside it
        /// while it's overridden. Keyed by the raw values of
        /// `DownloadResolution` and `DownloadBitratePreset`.
        static func ladderField(_ resolution: String, _ preset: String) -> String {
            "downloadsSettings.ladder.\(resolution).\(preset).field"
        }
        static func ladderReset(_ resolution: String, _ preset: String) -> String {
            "downloadsSettings.ladder.\(resolution).\(preset).reset"
        }
        static let ladderResetAll = "downloadsSettings.ladder.resetAll"
        /// The confirmation dialog's own Reset All to Defaults.
        static let ladderResetAllConfirm = "downloadsSettings.ladder.resetAll.confirm"
    }

    /// The sheet a long press on a detail page's Download button opens
    /// (`AdvancedDownloadOptionsView`).
    enum AdvancedDownloadOptions {
        /// The Version picker, shown for a title with two or more (#289).
        static let versionPicker = "advancedDownload.version"
        /// A Version menu option, by its `MediaVersion.id`.
        static func versionOption(_ versionID: String) -> String { "advancedDownload.version.\(versionID)" }
        static let resolutionPicker = "advancedDownload.resolution"
        static let qualityPicker = "advancedDownload.quality"
        /// A Quality menu option, by `DownloadBitratePreset`'s raw value.
        static func qualityOption(_ preset: String) -> String { "advancedDownload.quality.\(preset)" }
        /// The Estimated Size row's value.
        static let estimatedSize = "advancedDownload.estimatedSize"
        static let downloadButton = "advancedDownload.download"
        static let cancelButton = "advancedDownload.cancel"
    }

    /// Profile → About's License and Privacy Policy pages.
    enum About {
        /// The app's own licence text, first on the License page.
        static let appLicense = "about.license.app"
        /// A bundled library's heading on the License page, by its name.
        static func licenseComponent(_ name: String) -> String { "about.license.component.\(name)" }
        static let privacyPolicyText = "about.privacyPolicy.text"
    }

    /// Shared across every surface that renders a media tile, so a test can
    /// address one specific item wherever it appears.
    /// Approving another device's code, pushed from the Account screen.
    enum QuickConnectApproval {
        static let instructions = "quickConnectApproval.instructions"
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

    /// The UI-test harness's own probes, mounted only under its launch flags.
    enum UITest {
        /// `UITestAnnouncementProbe`: its label is the last VoiceOver
        /// announcement, under `-UITestSimulateVoiceOver`.
        static let lastAnnouncement = "uitest.lastAnnouncement"
        /// `UITestTimeZoneProbe`: its label is the app's
        /// `TimeZone.current.identifier`, under `-UITestShowTimeZone`.
        static let timeZone = "uitest.timeZone"
        /// The still the scrub bubble last showed, as
        /// `UITestTrickplay.describe` puts it (`scrubThumbnails` only).
        static let lastScrubPreview = "uitest.lastScrubPreview"
    }

    /// The Apple TV app's identifiers. Never on a screen-root container (see the
    /// file's header); each sits on a concrete element inside the screen.
    enum TV {
        enum Onboarding {
            /// The splash's spinner, shown once restoring the session takes
            /// three seconds; the splash itself is decorative.
            static let splashSpinner = "tv.onboarding.splash.spinner"
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
            static let signingInTo = "tv.onboarding.whosWatching.signingInTo"
            static let passwordSignIn = "tv.onboarding.password.signIn"
            /// Why a sign-in was refused, in red: on Who's Watching, the
            /// password screen and Other's form.
            static let signInError = "tv.onboarding.signIn.error"
            /// Why a server couldn't be reached, in red, on Find Your Server.
            static let serverSetupError = "tv.onboarding.findServer.error"
            /// A discovered HTTPS server's plain-HTTP fallback (#429): the
            /// port page shown when nothing answers on 8096, and the
            /// question's Connect Over HTTP (its Cancel is
            /// `TV.confirmationCancel`).
            static let httpPortField = "tv.onboarding.httpPort.field"
            static let httpPortTry = "tv.onboarding.httpPort.try"
            static let httpPortCancel = "tv.onboarding.httpPort.cancel"
            static let insecureFallbackConfirm = "tv.onboarding.insecureFallback.confirm"
            /// Other's username field, with Quick Connect off.
            static let manualUsername = "tv.onboarding.manual.username"
            static let getNewCode = "tv.onboarding.quickConnect.getNewCode"
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
            /// Recent Searches' heading row, one container named for it (M5).
            static let recentHeader = "tv.search.recentHeader"
            static let recentHeading = "tv.search.recentHeading"
        }
        enum Library {
            static let count = "tv.library.count"
            static let sort = "tv.library.sort"
            static func filter(_ facet: String) -> String { "tv.library.filter.\(facet)" }
            static let resetFilters = "tv.library.resetFilters"
            /// A choice in an open pill's list: "all", or the option's index.
            static func option(_ pill: String, _ option: String) -> String { "tv.library.option.\(pill).\(option)" }
            /// An open pill's list, one container named for its pill (M5).
            static func list(_ pill: String) -> String { "tv.library.list.\(pill)" }
            /// A long list's scrolled rows, named again: a scroll view is a
            /// container of its own, and VoiceOver names the innermost (M5).
            static func listRows(_ pill: String) -> String { "tv.library.list.\(pill).rows" }
            /// A group of choices in an open list (the sort's fields, its order).
            static func listSection(_ pill: String, _ index: Int) -> String { "tv.library.list.\(pill).\(index)" }
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
            /// Go Back, on the page for an item gone from the server.
            static let back = "tv.detail.back"
            static func similar(_ itemID: String) -> String { "tv.detail.similar.\(itemID)" }
            static func cast(_ memberID: String) -> String { "tv.detail.cast.\(memberID)" }
            /// Cast & Crew, one container named for its heading (M5).
            static let castGroup = "tv.detail.castGroup"
            static let castHeading = "tv.detail.castHeading"
            /// Cast & Crew's lazy row, named again: VoiceOver says the name of
            /// the container it enters, and a lazy stack is one of its own.
            static let castRow = "tv.detail.castRow"
            /// More Like This: its heading, its container and its lazy row.
            static let similarHeading = "tv.detail.similarHeading"
            static let similarGroup = "tv.detail.similarGroup"
            static let similarRow = "tv.detail.similarRow"
            static let details = "tv.detail.details"
            static let fullDetailsTitle = "tv.detail.fullDetails.title"
            /// A Full Details section ("about", "audio.<version>"…), one container
            /// named for its heading (M5), and that heading.
            static func fullDetailsSection(_ id: String) -> String { "tv.detail.fullDetails.section.\(id)" }
            static func fullDetailsSectionTitle(_ id: String) -> String { "tv.detail.fullDetails.sectionTitle.\(id)" }
            /// A version's tab in Full Details, by `MediaVersion.id` (#289);
            /// only a title with more than one version has them.
            static func versionTab(_ versionID: String) -> String { "tv.detail.fullDetails.version.\(versionID)" }
            /// Which episode a show page's Details describe.
            static let detailsSubject = "tv.detail.details.subject"
            static func season(_ seasonID: String) -> String { "tv.detail.season.\(seasonID)" }
            static func episode(_ episodeID: String) -> String { "tv.detail.episode.\(episodeID)" }
            static let noEpisodes = "tv.detail.noEpisodes"
            /// A box set's movie or a playlist's entry.
            static func member(_ id: String) -> String { "tv.detail.member.\(id)" }
            static let emptyMessage = "tv.detail.empty"
            static let loading = "tv.detail.loading"
            /// The row of format badges, read as one element (M5).
            static let badges = "tv.detail.badges"
            /// The poster or still beside the title, for a title with no backdrop.
            static let headerArt = "tv.detail.headerArt"
            /// More Actions, after Favorite.
            static let more = "tv.detail.more"
        }
        /// A detail page's More Actions: its menu's rows, the playlist
        /// picker and the new-playlist form.
        enum Actions {
            /// Add to Playlist and Delete rows, keyed by the target's id.
            static func addToPlaylist(_ itemID: String) -> String { "tv.actions.addToPlaylist.\(itemID)" }
            static func delete(_ itemID: String) -> String { "tv.actions.delete.\(itemID)" }
            /// The submenus offered when there are several targets.
            static let addSubmenu = "tv.actions.addToPlaylist"
            static let deleteSubmenu = "tv.actions.delete"
            static let deleteConfirm = "tv.actions.delete.confirm"
            static let newPlaylist = "tv.actions.newPlaylist"
            /// An existing playlist the user may edit, keyed by its id.
            static func playlistRow(_ playlistID: String) -> String { "tv.actions.playlist.\(playlistID)" }
            static let emptyState = "tv.actions.playlists.empty"
            static let playlistsRetry = "tv.actions.playlists.retry"
            static let addConfirm = "tv.actions.add.confirm"
            static let nameField = "tv.actions.newPlaylist.name"
            static let visibilityToggle = "tv.actions.newPlaylist.visibility"
            static let create = "tv.actions.newPlaylist.create"
            static let createConfirm = "tv.actions.newPlaylist.create.confirm"
        }
        /// `TVConfirmation`'s Cancel, wherever it asks.
        static let confirmationCancel = "tv.confirmation.cancel"
        /// `TVVersionPickerPage`'s heading, "Choose a Version" (#289).
        static let versionPickerTitle = "tv.versions.title"
        /// One version's button on `TVVersionPickerPage`, keyed by its
        /// `MediaVersion.id`, since its label may carry "(Last Played)".
        static func versionOption(_ versionID: String) -> String { "tv.versions.option.\(versionID)" }
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
            static let subtitleAppearance = "tv.profile.subtitleAppearance"
            static let advanced = "tv.profile.advanced"
            /// Playback → Night Mode (`TVNightModePage`): its row, the
            /// switches, each level's and time's value (under VoiceOver the
            /// whole row) and buttons, the schedule's switch, and the note
            /// shown while both times are the same.
            static let nightMode = "tv.profile.night.link"
            static let nightToggle = "tv.profile.night.toggle"
            static let nightAudio = "tv.profile.night.nightAudio"
            static let nightVolume = "tv.profile.night.volume"
            static let nightBrightness = "tv.profile.night.brightness"
            static func nightControl(_ level: String, _ control: String) -> String { "tv.profile.night.\(level).\(control)" }
            static let nightSchedule = "tv.profile.night.schedule"
            static let nightTurnOn = "tv.profile.night.turnOn"
            static let nightTurnOff = "tv.profile.night.turnOff"
            /// A time's − and +: `turnOn` or `turnOff`, then `decrease` or
            /// `increase`, e.g. `tv.profile.night.turnOn.increase`.
            static func nightTimeControl(_ time: String, _ control: String) -> String { "tv.profile.night.\(time).\(control)" }
            static let nightSameTimesNote = "tv.profile.night.sameTimesNote"
            static let nightRows = "tv.profile.night.rows"
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
            /// Profile → Playback → Audio Offset (`TVAudioOffsetPage`).
            static let audioOffset = "tv.profile.audioOffset"
            static let spatialAtmos = "tv.profile.spatialAudio.atmos"
            static let spatialAtmosLayout = "tv.profile.spatialAudio.atmos.layout"
            static let spatialDTSX = "tv.profile.spatialAudio.dtsx"
            static let spatialDTSXLayout = "tv.profile.spatialAudio.dtsx.layout"
            /// Opens the About Spatial Audio page (a `TVTextPageView`).
            static let spatialAudioAbout = "tv.profile.spatialAudio.about"
            static let audioOffsetDecrease = "tv.profile.audioOffset.decrease"
            static let audioOffsetIncrease = "tv.profile.audioOffset.increase"
            static let audioOffsetValue = "tv.profile.audioOffset.value"
            static let audioOffsetReset = "tv.profile.audioOffset.reset"
            /// A section's rows, one container named for its heading (M5).
            static func section(_ id: String) -> String { "tv.profile.section.\(id)" }
            static func sectionHeading(_ id: String) -> String { "tv.profile.section.\(id).heading" }
            /// A picker's or Advanced's title, and their rows as one
            /// container named for it (M5).
            static let pageTitle = "tv.profile.pageTitle"
            static let pickerOptions = "tv.profile.picker.options"
            static let advancedRows = "tv.profile.advanced.rows"
            static let readAheadBuffer = "tv.profile.readAheadBuffer"
            static let readAheadBufferValue = "tv.profile.readAheadBuffer.value"
            static let readAheadBufferDecrease = "tv.profile.readAheadBuffer.decrease"
            static let readAheadBufferIncrease = "tv.profile.readAheadBuffer.increase"
            static let readAheadBufferReset = "tv.profile.readAheadBuffer.reset"
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
            /// The Audio tab's offset rows (`TVPlayerPanelView.audioContent`).
            static let audioTracksHeading = "tv.player.audioTracks.heading"
            static let audioOffsetHeading = "tv.player.audioOffset.heading"
            static let audioOffsetRow = "tv.player.audioOffset"
            static let audioOffsetScope = "tv.player.audioOffset.scope"
            static let audioOffsetReset = "tv.player.audioOffset.reset"
            /// The Night tab's rows (`TVPlayerPanelView.nightContent`). The
            /// tab itself is `panelTab("night")`. The dimming layer has no
            /// identifier: journeys read its level from Playback Stats'
            /// "Night Mode" row.
            static let nightToggle = "tv.player.night.toggle"
            static let nightAudio = "tv.player.night.nightAudio"
            /// A level's value (label the level's name, value "60%"); in
            /// the accessible transport, the whole adjustable row.
            static let nightVolume = "tv.player.night.volume"
            static let nightBrightness = "tv.player.night.brightness"
            /// A level's control: `min`, `decrease`, `increase` or `max`,
            /// e.g. `tv.player.night.volume.decrease`.
            static func nightControl(_ level: String, _ control: String) -> String { "tv.player.night.\(level).\(control)" }
            /// The moon beside the elapsed time while Night Mode is on.
            static let nightIndicator = "tv.player.night.indicator"
            static let transport = "tv.player.transport"
            static let titleBlock = "tv.player.title"
            static let elapsed = "tv.player.elapsed"
            static let remaining = "tv.player.remaining"
            static let formatLabel = "tv.player.format"
            static let scrubPreview = "tv.player.scrubPreview"
            static let bufferedRange = "tv.player.buffered"
            static let scanIndicator = "tv.player.scan"
            static let actionFlash = "tv.player.flash"
            /// The spinner drawn while playback loads or rebuffers.
            static let buffering = "tv.player.buffering"
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
