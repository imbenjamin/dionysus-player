import Foundation
import Observation

@MainActor
@Observable
final class AssetDetailViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What the detail views render as the page's hero, synopsis, metadata, Play
    /// button and tabs. A Movie, or a Series tapped directly, is the requested
    /// item itself.
    ///
    /// A Season or Episode tapped directly still shows the Show's page (see
    /// `seriesID`/`preselectedSeasonID`), but only a Season selection swaps
    /// `item` to the Series. An Episode selection keeps `item` as that episode,
    /// so its own overview, artwork and technical details show — matching what
    /// other Jellyfin clients do for a deep link to an episode.
    private(set) var item: MediaItem?
    /// The Show these seasons and episodes belong to, set alongside `item` for
    /// any Series, Season or Episode load. Distinct from `item.id`, which can be
    /// an Episode's while this is its parent Series' — the id
    /// `SeasonEpisodeList` and `showPlaybackEpisode` scope their fetches by.
    private(set) var seriesID: String?
    /// Which season the picker defaults to rather than the first: the tapped
    /// Season, or an Episode's parent. `nil` for a Series tapped directly,
    /// falling back to the first season.
    private(set) var preselectedSeasonID: String?
    private(set) var seasons: [MediaItem] = []
    private(set) var similar: [MediaItem] = []
    private(set) var collections: [MediaItem] = []
    /// A BoxSet's child movies, for `CollectionDetailView`'s
    /// `CollectionItemList`. Empty for every other item type.
    ///
    /// Fetched alongside `similar`/`collections` in `load()` with the same
    /// non-fatal treatment, and re-fetched at the end of `refreshItem()` so a
    /// movie played straight from the grid — which never runs its own detail
    /// page's `refreshItem()` — still updates its watched overlay.
    private(set) var collectionItems: [MediaItem] = []
    /// A Playlist's members in its stored order: `PlaylistDetailView`'s
    /// `PlaylistItemList`, and the array `PlayerView`'s `playbackQueue` plays
    /// through. Empty for every other item type.
    ///
    /// AUDIO SUPPRESSION: audio members are filtered out before assignment, so
    /// this is a playable array and nothing downstream needs to filter again.
    ///
    /// Fetched alongside `similar`/`collections` in `load()` with the same
    /// non-fatal treatment — a failure leaves this empty, which
    /// `PlaylistDetailView` treats as an empty playlist — and re-fetched at the
    /// end of `refreshItem()`.
    private(set) var orderedPlaylistItems: [MediaItem] = []

    /// Whether this user may edit this playlist, gating `PlaylistItemList`'s
    /// remove affordances entirely — rendering nothing rather than a disabled
    /// control, as `canDelete` does for `AssetActionsButton`.
    ///
    /// Computed once per `load()`/`refreshItem()` from
    /// `JellyfinAPIClient.playlistUserPermissions`, which explains why it can't
    /// be derived locally. Playlist-wide, since every member shares one
    /// permission, and fail-closed to `false`.
    private(set) var canEditPlaylist: Bool = false
    private(set) var loadState: LoadState = .idle

    /// The Show's own item, set alongside `seriesID` whether or not `item` is
    /// that same Show. Exists for `PlayResumeButtonRow`'s favorite and watched
    /// menu, the one place needing the Show's status while `item` shows an
    /// Episode's. `nil` for a Movie.
    private(set) var seriesItem: MediaItem?

    /// For Show content only: the episode `PlayResumeButtonRow` targets, resolved
    /// during `load()` so the button can read "Play S2:E4" rather than a bare
    /// label. `nil` for Movie and Episode content, where `item` is already the
    /// thing to play, and briefly `nil` for a Show until `load()` resolves it.
    ///
    /// Resolution depends on how the page was reached:
    /// - A Season tapped directly gives that season's first episode — a Season
    ///   tap reads as "start this season", not "continue the show".
    /// - A Series tapped directly gives Jellyfin's NextUp, which returns an
    ///   in-progress episode if one exists and otherwise the next unwatched one,
    ///   falling back to the first episode of the first season for a show never
    ///   started.
    ///
    /// Either way `PlayResumeButtonRow` decides Play versus Resume from this
    /// episode's own watched state via `effectiveItem`, not an aggregate on the
    /// Series — which is what makes a Season tap say "Resume" when its first
    /// episode is already part-watched.
    private(set) var showPlaybackEpisode: MediaItem?

    /// `PlaylistDetailView`'s Play/Resume target. Unlike `showPlaybackEpisode`
    /// this needs no round trip: Jellyfin has no NextUp for playlists —
    /// `/Shows/NextUp` is Series-scoped and `/Playlists/{id}/InstantMix` is an
    /// unrelated radio feature — so it comes from `orderedPlaylistItems`'
    /// already-fetched `userData`: the first member not fully played, or the
    /// first item when all are, for a full replay.
    ///
    /// `nil` exactly when `orderedPlaylistItems` is empty, where
    /// `PlaylistDetailView` hides the row rather than showing one with nothing
    /// to target.
    var playlistResumeTarget: MediaItem? {
        orderedPlaylistItems.first(where: { !$0.isPlayed }) ?? orderedPlaylistItems.first
    }

    /// The id `refreshItem()` re-fetches to keep `item` current: `itemID` itself
    /// for a Movie, Series or Episode load, but the Series' id for a Season load,
    /// where `item` was swapped to the Series' DTO.
    private var displayedItemID: String?

    let itemID: String
    private let client: JellyfinAPIClient
    private let userID: String
    private let versionPreferenceStore: MediaVersionPreferenceStore

    /// Exposed read-only for `DownloadButton`'s call sites, which hold this view
    /// model but no `client` or `userID` of their own.
    var apiClient: JellyfinAPIClient { client }
    var currentUserID: String { userID }

    /// `preloadedItem` seeds `item` immediately, so the page has something to
    /// render — and a zoom transition something to land on — before `load()`'s
    /// round trip resolves. It is partial, fetched via a rail's lighter `Fields`
    /// list, so `load()` runs regardless and replaces it.
    init(
        client: JellyfinAPIClient, userID: String, itemID: String, preloadedItem: MediaItem? = nil,
        versionPreferenceStore: MediaVersionPreferenceStore = MediaVersionPreferenceStore()
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.item = preloadedItem
        self.versionPreferenceStore = versionPreferenceStore
    }

    /// The version a Resume tap continues with: whatever was chosen via the
    /// version prompt when that item was last started fresh, or `nil` to let
    /// `PlayerViewModel` fall back to the server's default.
    func preferredMediaSourceID(forPlayableItem playableItemID: String) -> String? {
        versionPreferenceStore.preferredMediaSourceID(forItem: playableItemID, userID: userID)
    }

    /// Records the version-choice prompt's answer so a later "Resume" (see
    /// `preferredMediaSourceID(forPlayableItem:)`) continues the same one.
    func setPreferredMediaSourceID(_ mediaSourceID: String, forPlayableItem playableItemID: String) {
        versionPreferenceStore.setPreferredMediaSourceID(mediaSourceID, forItem: playableItemID, userID: userID)
    }

    /// Guards on `loadState`, not `item`: a preloaded item makes `item` non-nil
    /// before `load()` has run, which would read as nothing to reload and skip
    /// fetching cast, technical details and the rails entirely.
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)

            // The one place that decides `item`, `seriesID`,
            // `preselectedSeasonID` and `displayedItemID`; see each for what a
            // branch is establishing.
            switch dto.type {
            case .episode:
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                seriesID = dto.seriesId
                preselectedSeasonID = dto.seasonId
                // Unlike the Season case below, `item` stays the Episode, so the
                // Show's item needs its own fetch rather than reusing `item`.
                if let seriesID, let seriesDTO = try? await client.item(userID: userID, itemID: seriesID) {
                    seriesItem = MediaItem(dto: seriesDTO, images: images)
                }
            case .season:
                if let seriesID = dto.seriesId {
                    // The page shows the Show's item, not the Season's, which has
                    // no overview or artwork worth showing — the one case where
                    // `displayedItemID` differs from `itemID`.
                    self.seriesID = seriesID
                    preselectedSeasonID = dto.id
                    let seriesDTO = try await client.item(userID: userID, itemID: seriesID)
                    item = MediaItem(dto: seriesDTO, images: images)
                    seriesItem = item
                    displayedItemID = seriesID
                    // `preselectedSeasonID`, just set above, tells
                    // `resolveShowPlaybackEpisode` this is a Season tap's target.
                    await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
                } else {
                    // Shouldn't happen; degrades to the Season's mostly-empty
                    // item rather than crashing.
                    item = MediaItem(dto: dto, images: images)
                    displayedItemID = itemID
                }
            default:
                // Series, or a Movie, BoxSet or anything else — none of which
                // have a `seriesID` except Series, set below.
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                if dto.type == .series {
                    seriesID = dto.id
                    seriesItem = item
                }
                preselectedSeasonID = nil
            }

            // AUDIO SUPPRESSION: `item` and `displayedItemID` are set above, so
            // `AssetDetailView` can render its unsupported state. Nothing below
            // renders once it does, so the remaining fetches are skipped. An
            // efficiency guard, not a correctness one — delete once audio
            // playback is supported.
            guard !dto.isAudioContent else {
                loadState = .loaded
                return
            }

            // Similar and collections scope to the Show for every Series, Season
            // and Episode case, an episode's own similar items being meaningless
            // through the API. Falls back to `itemID` only for a Movie.
            //
            // These and `seasons` are `try?`: supplementary rails, not the page,
            // which has already resolved. Only the primary item fetch and the
            // Series swap-in can still fail the whole page. A hiccup on
            // `/Similar` otherwise took an already-loaded hero and Play button
            // down to a full-screen error instead of leaving one rail empty.
            let similarCollectionsID = seriesID ?? itemID
            async let similarResult = try? client.similarItems(itemID: similarCollectionsID, userID: userID)
            async let collectionsResult = try? client.collectionsContaining(itemID: similarCollectionsID, userID: userID)
            // Scoped to `.boxSet` rather than fetched and discarded for other
            // kinds: a Movie or Episode has no children, and a Series' are
            // `seasons`, fetched separately below.
            async let collectionItemsResult: BaseItemDtoQueryResult? = dto.type == .boxSet
                ? try? client.items(userID: userID, parentID: itemID, recursive: false, sortBy: "PremiereDate")
                : nil
            // Gated on `.playlist`, as `collectionItemsResult` is on `.boxSet`.
            async let orderedPlaylistItemsResult: BaseItemDtoQueryResult? = dto.type == .playlist
                ? try? client.playlistItems(playlistID: itemID, userID: userID)
                : nil
            // `canEditPlaylist`'s own fetch — see that property's doc
            // comment. Gated on `.playlist` the same way the fetch above
            // is; a non-playlist page never calls this endpoint at all.
            async let canEditPlaylistResult: PlaylistUserPermissions? = dto.type == .playlist
                ? try? client.playlistUserPermissions(playlistID: itemID, userID: userID)
                : nil

            if let seriesID, let seasonsResult = try? await client.seasons(seriesID: seriesID, userID: userID) {
                seasons = seasonsResult.items.map { MediaItem(dto: $0, images: images) }
            }

            // Series tapped directly — see `showPlaybackEpisode`'s doc
            // comment. `dto.type == .series` (the *originally requested*
            // item's real kind), not `item?.kind`, since a Season load also
            // ends up with `item.kind == .series` after the swap above but
            // already resolved its own (season-scoped) target just above —
            // `resolveShowPlaybackEpisode` tells the two apart via
            // `preselectedSeasonID` (`nil` here, set for the Season case).
            if dto.type == .series, let seriesID {
                await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
            }

            if let similarItems = await similarResult {
                similar = similarItems.items.map { MediaItem(dto: $0, images: images) }
            }
            if let collectionsItems = await collectionsResult {
                collections = collectionsItems.map { MediaItem(dto: $0, images: images) }
            }
            if let collectionItemsItems = await collectionItemsResult {
                collectionItems = collectionItemsItems.items.map { MediaItem(dto: $0, images: images) }
            }
            // AUDIO SUPPRESSION: see `orderedPlaylistItems`'s doc comment —
            // audio/music members are dropped here, before assignment, so
            // this array is always safe to show and play through directly.
            if let playlistItemsResult = await orderedPlaylistItemsResult {
                orderedPlaylistItems = playlistItemsResult.items
                    .map { MediaItem(dto: $0, images: images) }
                    .filter { !$0.isAudioContent }
            }
            canEditPlaylist = await canEditPlaylistResult?.canEdit ?? false

            loadState = .loaded
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't load this title.")
            )
        }
    }

    /// Switches this Show page's displayed content to `episodeID` in place: a tap
    /// on an episode row's text area, as opposed to its play button, and
    /// `advanceToNextEpisodeIfCompleted()`'s swap once a next episode is
    /// confirmed.
    ///
    /// Fetches the episode's full item — technical details, versions, cast,
    /// unlike `SeasonEpisodeList`'s lighter list fetch — then swaps `item` and
    /// `displayedItemID` to it, producing the same shape a direct Episode tap
    /// does, so everything downstream follows `item` reactively.
    ///
    /// Leaves `seriesID`/`seasons` alone, the episode always being within the
    /// same Show, but does keep `preselectedSeasonID` current: a same-value
    /// reassignment for `SeasonEpisodeList.onSelectEpisode`, which can only pick
    /// within the selected season, but load-bearing for
    /// `advanceToNextEpisodeIfCompleted()`, which can cross a season boundary.
    func selectEpisode(_ episodeID: String) async {
        guard let dto = try? await client.item(userID: userID, itemID: episodeID) else { return }
        let images = await client.makeImageURLBuilder()
        item = MediaItem(dto: dto, images: images)
        displayedItemID = episodeID
        preselectedSeasonID = dto.seasonId
    }

    // MARK: - Deletion

    /// Where the UI goes once a deletion lands. Resolved here, which knows how
    /// the page was reached, and acted on by `AssetActionsButton`, which owns
    /// the environment values to carry it out.
    enum DeletionOutcome: Equatable {
        /// The page's subject still exists — an episode picked in place, or a
        /// season of a show with others. `delete(_:)` has already repaired it.
        case stayAndRefresh
        /// The page was showing what was deleted, and what's underneath is valid.
        case popOneLevel
        /// What's underneath is gone too — the show's last episode went with it
        /// — so popping onto it would land on a dead screen.
        case popToRoot
    }

    /// Items with a deletion in flight, disabling the control and showing a
    /// spinner. A set rather than one flag, as `pendingFavoriteIDs` is, because
    /// a show page's menu offers Show, Season and Episode independently.
    private(set) var deletingItemIDs: Set<String> = []

    /// Deletes `target` from the server, including the media file itself (see
    /// `JellyfinAPIClient.deleteItem`). Throws on failure so the caller can
    /// surface it; on success, repairs this page's state and reports where the
    /// UI should go.
    ///
    /// Not wrapped in `track(_:)`, unlike the other fire-and-forget tasks here:
    /// `AssetDetailView.onDisappear` cancels tracked tasks, and this one often
    /// ends in a dismissal that would cancel the request causing it, leaving the
    /// deletion half-done.
    @discardableResult
    func delete(_ target: MediaItem) async throws -> DeletionOutcome {
        deletingItemIDs.insert(target.id)
        defer { deletingItemIDs.remove(target.id) }

        try await client.deleteItem(itemID: target.id)

        // Announced before the outcome is resolved, which costs another round
        // trip, so screens underneath react immediately.
        DeletedItemBroadcaster.shared.record(itemID: target.id)

        let outcome = await resolveDeletionOutcome(for: target)
        if outcome == .stayAndRefresh {
            await repairPageAfterDeletion(of: target)
        }
        return outcome
    }

    /// Removes `item` from this playlist, optimistically — unlike `delete(_:)`,
    /// removing a membership touches no file and is reversible by re-adding.
    /// `orderedPlaylistItems` updates before the network call starts, so the row
    /// animates away immediately; on failure `item` is reinserted at its original
    /// index and the error rethrown for the caller to surface.
    ///
    /// A no-op when `item.playlistItemID` is `nil` or absent from
    /// `orderedPlaylistItems`. That shouldn't happen for a rendered row, but it
    /// guards a duplicate invocation — the swipe action and context menu firing
    /// for the same row — from double-removing or resurrecting an item.
    func removeFromPlaylist(_ item: MediaItem) async throws {
        guard let entryID = item.playlistItemID,
              let index = orderedPlaylistItems.firstIndex(where: { $0.playlistItemID == entryID }) else { return }

        orderedPlaylistItems.remove(at: index)
        do {
            try await client.removePlaylistItems(playlistID: itemID, entryIDs: [entryID])
        } catch {
            orderedPlaylistItems.insert(item, at: min(index, orderedPlaylistItems.count))
            throw error
        }
    }

    private func resolveDeletionOutcome(for target: MediaItem) async -> DeletionOutcome {
        switch target.kind {
        case .episode, .season:
            guard let seriesID else { return .popOneLevel }

            // Ask the server what's left rather than subtracting from a count
            // fetched before the delete. A failure is informative: Jellyfin drops
            // a series once its last episode goes, so a 404 means there is
            // nothing to go back to.
            guard let seriesDTO = try? await client.item(userID: userID, itemID: seriesID) else {
                return .popToRoot
            }
            if let remaining = seriesDTO.recursiveItemCount, remaining == 0 {
                return .popToRoot
            }

            if target.kind == .season { return .stayAndRefresh }
            // An episode reached by its own push is this page, so pop. One picked
            // in place isn't: `itemID` is still the show's, and that page remains
            // valid.
            return target.id == itemID ? .popOneLevel : .stayAndRefresh
        default:
            return .popOneLevel
        }
    }

    /// Restores the page after deleting something it displayed but needn't leave
    /// over: swaps the hero back to the show, re-reads the season list, and
    /// forces the episode list to re-fetch.
    private func repairPageAfterDeletion(of target: MediaItem) async {
        let images = await client.makeImageURLBuilder()

        // The hero was showing an episode that no longer exists.
        if target.kind == .episode, let seriesItem {
            item = seriesItem
            displayedItemID = seriesItem.id
        }

        if let seriesID, let seasonsResult = try? await client.seasons(seriesID: seriesID, userID: userID) {
            seasons = seasonsResult.items.map { MediaItem(dto: $0, images: images) }
            // The picker could be pointing at the deleted season; fall back to
            // whichever now comes first.
            if let preselectedSeasonID, !seasons.contains(where: { $0.id == preselectedSeasonID }) {
                self.preselectedSeasonID = seasons.first?.id
            }
        }

        // `SeasonEpisodeList` fetches independently of `item`, so without this
        // the deleted episode's row stays on screen.
        episodeListRefreshToken = UUID()
    }

    /// Items with a favorite toggle in flight, so `HeroActionButtons` shows a
    /// spinner rather than an inert star while the request and its confirmation
    /// re-fetch run, which can take a couple of seconds. Keyed by id rather than
    /// one flag, since a Show page's menu toggles Show, Season and Episode
    /// independently.
    private(set) var pendingFavoriteIDs: Set<String> = []
    /// See `pendingFavoriteIDs` — identical shape, watched status instead.
    private(set) var pendingWatchedIDs: Set<String> = []

    /// `itemID`'s live favorite and watched status from whichever of `item`,
    /// `seriesItem`, `showPlaybackEpisode` or `seasons` holds it — the targets
    /// `applyOptimisticFavoriteWatched` and `refetchFavoriteWatchedTarget` patch.
    /// `HeroActionButtons` calls this as a toggle fires rather than trusting the
    /// `MediaItem` its closure captured.
    ///
    /// A SwiftUI toolbar bug makes that necessary. `HeroActionButtons` is a
    /// `ToolbarItem`, and while its displayed icon tracks `item` reactively, the
    /// `Button` action closures underneath keep firing with the snapshot
    /// captured the first time the toolbar content was built, many renders
    /// later. Tapping Favorite, waiting for it to confirm, then tapping again
    /// read `currentlyFavorite` as the value from before the first tap, so the
    /// second write repeated the first instead of reversing it.
    ///
    /// Reading through the view model — one stable reference for the page —
    /// sidesteps that however stale the closure is. Falls back to the caller's
    /// belief if `itemID` matches nothing held, which shouldn't happen.
    func currentFavoriteWatchedStatus(forItemID itemID: String) -> (favorite: Bool, watched: Bool)? {
        if let item, item.id == itemID { return (item.isFavorite, item.isPlayed) }
        if let seriesItem, seriesItem.id == itemID { return (seriesItem.isFavorite, seriesItem.isPlayed) }
        if let showPlaybackEpisode, showPlaybackEpisode.id == itemID {
            return (showPlaybackEpisode.isFavorite, showPlaybackEpisode.isPlayed)
        }
        if let season = seasons.first(where: { $0.id == itemID }) { return (season.isFavorite, season.isPlayed) }
        return nil
    }

    /// Fire-and-forget `Task`s wrapping this view model's async methods,
    /// registered by their call sites via `track(_:)`. `cancelBackgroundWork()`,
    /// from `AssetDetailView.onDisappear`, stops them once the page is off
    /// screen — otherwise a favorite toggle's confirmation poll or a
    /// post-playback refresh, both up to ~13s, keeps issuing requests against a
    /// screen nobody is looking at.
    ///
    /// The methods stay plain `async` functions any caller can `await` directly;
    /// only UI call sites route through `track(_:)`.
    private var backgroundTasks: [Task<Void, Never>] = []

    /// See `backgroundTasks`'s doc comment.
    func track(_ task: Task<Void, Never>) {
        backgroundTasks.append(task)
    }

    /// See `backgroundTasks`. Safe with nothing in flight: cancelling a finished
    /// `Task` is a no-op.
    func cancelBackgroundWork() {
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
    }

    /// Shared by `refetchFavoriteWatchedTarget` and `refreshItem()`. Jellyfin's
    /// write endpoints return 200 immediately but commit the userData change
    /// asynchronously, with variable latency: a Movie or Episode's favorite
    /// status confirms well under a second, while a Series' sometimes takes
    /// several seconds longer on the same item.
    ///
    /// A shorter ~3.25s schedule wasn't enough for `refreshItem()`. Resuming a
    /// movie, scrubbing, and exiting within a few seconds leaves the stop report
    /// as the session's only report — playback progress reports every 10s — and
    /// that write landed correctly but outside the old window, leaving the
    /// detail page's progress bar on the pre-scrub position.
    private static let userDataCommitPollSchedule: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

    /// Toggles `itemID`'s favorite status. `itemID` is always `item.id` on a
    /// Movie or Episode page, but can be the Show's, the selected Season's or
    /// the current Episode's on a Show page. `currentlyFavorite` is the caller's
    /// value, flipped rather than re-derived.
    func toggleFavorite(itemID: String, currentlyFavorite: Bool) async {
        pendingFavoriteIDs.insert(itemID)
        defer { pendingFavoriteIDs.remove(itemID) }
        let newValue = !currentlyFavorite
        let succeeded = (try? await client.setFavorite(newValue, itemID: itemID, userID: userID)) != nil
        // Applied only once the write succeeded, so a failed request doesn't show
        // a false success. `applyOptimisticFavoriteWatched` covers why this can't
        // wait on the confirmation poll below.
        if succeeded { applyOptimisticFavoriteWatched(itemID: itemID, favorite: newValue) }
        await refetchFavoriteWatchedTarget(itemID: itemID, expectedFavorite: newValue)
    }

    /// `toggleFavorite(itemID:currentlyFavorite:)` for the watched status.
    func toggleWatched(itemID: String, currentlyWatched: Bool) async {
        pendingWatchedIDs.insert(itemID)
        defer { pendingWatchedIDs.remove(itemID) }
        let newValue = !currentlyWatched
        let succeeded = (try? await client.setWatched(newValue, itemID: itemID, userID: userID)) != nil
        if succeeded { applyOptimisticFavoriteWatched(itemID: itemID, watched: newValue) }
        await refetchFavoriteWatchedTarget(itemID: itemID, expectedWatched: newValue)
    }

    /// Reflects a just-succeeded favorite or watched write on whichever property
    /// holds `itemID`, the same targets `refetchFavoriteWatchedTarget` patches
    /// once the server confirms — the shape `applyOptimisticPlaybackPosition(_:)`
    /// also uses.
    ///
    /// That confirmation can take far longer than `userDataCommitPollSchedule`
    /// allows: a favorite write returned success immediately but took several
    /// minutes to commit server-side, an order of magnitude past the ~13s budget.
    /// Without this the poll kept re-fetching the pre-write value and patching it
    /// into `item`, so the button looked exactly as if the tap had done nothing.
    /// `refetchFavoriteWatchedTarget` no longer adopts an unconfirmed fetch, so
    /// nothing regresses this while the real commit is in flight.
    private func applyOptimisticFavoriteWatched(itemID: String, favorite: Bool? = nil, watched: Bool? = nil) {
        if let current = item, current.id == itemID {
            item = current.withOptimisticFavoriteWatched(favorite: favorite, watched: watched)
        }
        if let current = seriesItem, current.id == itemID {
            seriesItem = current.withOptimisticFavoriteWatched(favorite: favorite, watched: watched)
        }
        if let current = showPlaybackEpisode, current.id == itemID {
            showPlaybackEpisode = current.withOptimisticFavoriteWatched(favorite: favorite, watched: watched)
        }
        if let index = seasons.firstIndex(where: { $0.id == itemID }) {
            seasons[index] = seasons[index].withOptimisticFavoriteWatched(favorite: favorite, watched: watched)
        }
    }

    /// Re-fetches the just-toggled item and patches it into every property that
    /// might hold a stale copy, by id match. A toggle can target any of them
    /// independently, and more than one can match at once — toggling the Series'
    /// favorite status when `item` is that Series updates both `item` and
    /// `seriesItem`.
    ///
    /// Polls on `userDataCommitPollSchedule`. `expectedFavorite`/`expectedWatched`
    /// — whichever this call toggles, the other staying `nil` — is what it polls
    /// for: keep re-fetching until the server reports the value just written,
    /// not merely any response.
    private func refetchFavoriteWatchedTarget(itemID: String, expectedFavorite: Bool? = nil, expectedWatched: Bool? = nil) async {
        let images = await client.makeImageURLBuilder()
        for delay in Self.userDataCommitPollSchedule {
            try? await Task.sleep(for: .seconds(delay))
            // `try?` above swallows `Task.sleep`'s cancellation error, so this is
            // what stops the poll once `cancelBackgroundWork()` cancels the task —
            // otherwise a page backed out of mid-toggle polls out the schedule.
            guard !Task.isCancelled else { return }
            guard let dto = try? await client.item(userID: userID, itemID: itemID) else { continue }
            let updated = MediaItem(dto: dto, images: images)
            let favoriteConfirmed = expectedFavorite.map { $0 == updated.isFavorite } ?? true
            let watchedConfirmed = expectedWatched.map { $0 == updated.isPlayed } ?? true
            // Not confirmed: this is the server's still-uncommitted old value,
            // and adopting it would regress `item` and undo the toggle's
            // optimistic update. Skip and retry, as `refreshItem()`'s
            // `optimisticTarget` guard below does.
            guard favoriteConfirmed && watchedConfirmed else { continue }
            if item?.id == itemID { item = updated }
            if seriesItem?.id == itemID { seriesItem = updated }
            if showPlaybackEpisode?.id == itemID { showPlaybackEpisode = updated }
            if let index = seasons.firstIndex(where: { $0.id == itemID }) { seasons[index] = updated }
            break
        }
    }

    /// Immediately reflects a just-closed playback session's final position
    /// on whichever of `item`/`showPlaybackEpisode` was actually playing
    /// (`outcome.itemID` — `item` itself for a Movie/Episode-content page,
    /// `showPlaybackEpisode` for Show content played via the main button —
    /// see `PlayResumeButtonRow.targetEpisode`'s doc comment for that same
    /// split), rather than waiting on `refreshItem()`'s server poll to catch
    /// up — see `PlaybackSessionOutcome`'s own doc comment for why that poll
    /// alone isn't good enough here, however long its schedule is.
    ///
    /// Deliberately leaves `played`/the Watched badge alone — whether this
    /// position crosses Jellyfin's own "mark as watched" threshold is a
    /// server-side judgement call this isn't trying to replicate client-side
    /// (getting it wrong would show an actively *incorrect* status, worse
    /// than a briefly-stale-but-eventually-correct one). `refreshItem()`,
    /// called right after this from the same `onDismiss` (see
    /// `MovieDetailView`/`ShowDetailView`'s call sites), is what settles
    /// that.
    ///
    /// Also records `optimisticPlaybackTarget` — see that property's doc
    /// comment for why `refreshItem()` needs it: without it, the very poll
    /// this method is meant to be ahead of ends up undoing it.
    func applyOptimisticPlaybackPosition(_ outcome: PlaybackSessionOutcome) {
        guard outcome.durationSeconds > 0 else { return }
        optimisticPlaybackTarget = (
            itemID: outcome.itemID, ticks: Int64(outcome.positionSeconds * 10_000_000)
        )
        if let current = item, current.id == outcome.itemID {
            item = current.withOptimisticPlaybackPosition(seconds: outcome.positionSeconds, duration: outcome.durationSeconds)
        }
        if let current = showPlaybackEpisode, current.id == outcome.itemID {
            showPlaybackEpisode = current.withOptimisticPlaybackPosition(seconds: outcome.positionSeconds, duration: outcome.durationSeconds)
        }
        if let index = orderedPlaylistItems.firstIndex(where: { $0.id == outcome.itemID }) {
            orderedPlaylistItems[index] = orderedPlaylistItems[index]
                .withOptimisticPlaybackPosition(seconds: outcome.positionSeconds, duration: outcome.durationSeconds)
        }
    }

    /// Set by `applyOptimisticPlaybackPosition(_:)`, read and cleared by
    /// `refreshItem()`, whose poll would otherwise defeat it.
    ///
    /// That poll normally stops as soon as a fetch differs from what `item` held
    /// when it started. But by then `item` holds this session's optimistic guess
    /// rather than the server's last-known value, and the first attempt ~0.25s in
    /// almost always gets the server's old, uncommitted position — which
    /// "differs" from the guess, so the poll adopted it and stopped, overwriting
    /// the correct value with stale data.
    ///
    /// While this is set, `refreshItem()` instead ignores any fetch that hasn't
    /// caught up to within `optimisticPositionTolerance`, unless the server has
    /// independently decided the item is played, which resets its position and so
    /// would never catch up to a pre-played guess.
    ///
    /// Scoped by itemID rather than cleared every call: `refreshItem()`'s
    /// `displayedItemID` concerns only `item`, so a guess belonging to
    /// `showPlaybackEpisode` must be left alone.
    private var optimisticPlaybackTarget: (itemID: String, ticks: Int64)?

    /// How close a fetched position must be to `optimisticPlaybackTarget` to
    /// count as caught up. Not an exact match: the guess and what
    /// `PlayerViewModel.stop()` reports are read from the engine's clock a moment
    /// apart, so they differ by a second or two even once the right write has
    /// committed. Five seconds covers that drift while still rejecting the stale
    /// case — a resume position tens of minutes off from a scrub.
    private static let optimisticPositionTolerance: Int64 = 5 * 10_000_000

    /// Bumped at the end of every `refreshItem()`. `SeasonEpisodeList` folds it
    /// into its `.task(id:)`, so returning from playback re-fetches that season's
    /// rows — which fetch independently of `item` and would otherwise show stale
    /// progress until the season picker changed. A `UUID` because `.task(id:)`
    /// needs only a distinct `Equatable` value.
    private(set) var episodeListRefreshToken = UUID()

    /// Re-fetches the main item's DTO so the Play/Resume button and progress bar
    /// reflect the server's watch state after returning from the player.
    /// `episodeListRefreshToken` covers the sibling episode list. Skips
    /// `seasons`/`similar`/`collections`, which a playback session can't change.
    ///
    /// Polls `userDataCommitPollSchedule` until the returned userData differs
    /// from what we had, meaning the server caught up, or attempts run out.
    func refreshItem() async {
        // `displayedItemID`, not `itemID`: identical except on a Season load,
        // where `item` was swapped to the Show's DTO and re-fetching `itemID`
        // would overwrite it with the tapped Season's.
        guard let displayedItemID else { return }
        let previousTicks = item?.dto.userData?.playbackPositionTicks
        let previousPercentage = item?.dto.userData?.playedPercentage
        let previouslyPlayed = item?.dto.userData?.played
        // Only relevant when the guess belongs to `item` itself, not to a
        // `showPlaybackEpisode` this fetch has nothing to do with.
        let optimisticTarget = optimisticPlaybackTarget?.itemID == displayedItemID ? optimisticPlaybackTarget : nil
        // Captured before either task below can reassign `item`; see
        // `refreshShowPlaybackEpisodeIfNeeded`.
        let isShowContent = item?.kind == .series
        // Also captured up front rather than read inside
        // `advanceToNextEpisodeIfCompleted`, avoiding the race it documents.
        let playedEpisodeID = optimisticPlaybackTarget?.itemID
        let images = await client.makeImageURLBuilder()

        // Concurrent, not sequential: gating either behind the poll below left
        // it waiting out the poll's entire schedule for Show content.
        async let showPlaybackEpisodeUpdate: Void = refreshShowPlaybackEpisodeIfNeeded(isShowContent: isShowContent, images: images)
        async let nextEpisodeAdvance: Void = advanceToNextEpisodeIfCompleted(playedEpisodeID: playedEpisodeID)

        for delay in Self.userDataCommitPollSchedule {
            try? await Task.sleep(for: .seconds(delay))
            // As in `refetchFavoriteWatchedTarget`, relying on
            // `cancelBackgroundWork()`.
            guard !Task.isCancelled else { return }
            guard let dto = try? await client.item(userID: userID, itemID: displayedItemID) else { continue }

            // `advanceToNextEpisodeIfCompleted`, running concurrently, can swap
            // `displayedItemID` to a different episode mid-poll. This fetch is
            // then for a superseded item, and adopting it would clobber the
            // advance back to the episode just finished. The advance has already
            // produced the current state, so stop.
            guard self.displayedItemID == displayedItemID else { break }

            if let optimisticTarget {
                let fetchedTicks = dto.userData?.playbackPositionTicks ?? 0
                let played = dto.userData?.played ?? false
                let caughtUp = fetchedTicks >= optimisticTarget.ticks - Self.optimisticPositionTolerance || played
                // Not caught up: this is the server's uncommitted old value, and
                // adopting it would regress `item` to stale data — the bug this
                // property exists to fix. Skip and retry.
                guard caughtUp else { continue }
            }

            item = MediaItem(dto: dto, images: images)
            if optimisticPlaybackTarget?.itemID == displayedItemID { optimisticPlaybackTarget = nil }
            if dto.userData?.playbackPositionTicks != previousTicks
                || dto.userData?.playedPercentage != previousPercentage
                || dto.userData?.played != previouslyPlayed {
                break
            }
        }

        await showPlaybackEpisodeUpdate
        await nextEpisodeAdvance

        // A movie played straight from the grid never runs its own
        // `refreshItem()`, so `collectionItems` needs this re-fetch.
        //
        // After the polling loop rather than concurrent with it: a BoxSet's own
        // `userData` has nothing to do with a child's progress, so that loop runs
        // its whole schedule regardless — which buys enough time for the played
        // child's commit to land, piggybacking on the wait rather than polling
        // separately.
        if item?.kind == .boxSet, let childrenResult = try? await client.items(
            userID: userID, parentID: displayedItemID, recursive: false, sortBy: "PremiereDate"
        ) {
            collectionItems = childrenResult.items.map { MediaItem(dto: $0, images: images) }
        }

        // As for `collectionItems` above — a Playlist's poll never catches up
        // either — so `playlistResumeTarget` reflects each member's real watched
        // state after a session closes.
        if item?.kind == .playlist, let playlistItemsResult = try? await client.playlistItems(
            playlistID: displayedItemID, userID: userID
        ) {
            // AUDIO SUPPRESSION: see `orderedPlaylistItems`.
            orderedPlaylistItems = playlistItemsResult.items
                .map { MediaItem(dto: $0, images: images) }
                .filter { !$0.isAudioContent }
            // Permission rarely changes mid-session, but this keeps it current
            // like the fetch above.
            canEditPlaylist = (try? await client.playlistUserPermissions(
                playlistID: displayedItemID, userID: userID
            ))?.canEdit ?? false
        }

        // Bumped unconditionally rather than only when the poll detected a
        // change: `SeasonEpisodeList`'s fetch is single-shot with no
        // did-this-change check to gate on, and the worst case is a redundant
        // fetch of the same data.
        episodeListRefreshToken = UUID()
    }

    /// `refreshItem()`'s Show-content counterpart to its item poll, separate so
    /// it can run concurrently with that poll via `async let`.
    ///
    /// Run sequentially, it waited out the poll. That is fine for a Movie or
    /// Episode page, where the poll and this update watch the same thing, but for
    /// Show content the loop watches the Series' `userData`, which essentially
    /// never reflects one episode's progress — so its exit condition never fires
    /// and it exhausts its full ~13s schedule every time, delaying
    /// `showPlaybackEpisode` regardless of how fast the server committed.
    ///
    /// `isShowContent` is a parameter captured before either task starts rather
    /// than read here, since the poll may have reassigned `item` by the time an
    /// `async let` call runs.
    private func refreshShowPlaybackEpisodeIfNeeded(isShowContent: Bool, images: ImageURLBuilder) async {
        guard isShowContent, let seriesID else { return }
        await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
    }

    /// After a session closes, checks whether the episode that played is now
    /// fully watched and, if NextUp resolves to a different one, advances this
    /// page to it via `selectEpisode(_:)` — reusing its fetch-and-swap and its
    /// `preselectedSeasonID` update, so the season picker follows across a
    /// boundary.
    ///
    /// A Show-direct page becomes an Episode-content page this way, by design:
    /// `isEpisodeContent` is purely `item?.kind == .episode`, so once `item`
    /// swaps, the existing Episode rendering takes over with no new branching.
    ///
    /// Its own poll rather than part of `refreshItem()`'s: for a Show-direct
    /// page the episode that played and `displayedItemID` are different items,
    /// and that poll fetches the Series' DTO, which can't answer whether one
    /// episode is played. Concurrent with it for the same reason
    /// `refreshShowPlaybackEpisodeIfNeeded` is. Since this can mutate
    /// `item`/`displayedItemID` via `selectEpisode` while that poll runs, that
    /// loop carries a matching guard.
    ///
    /// A no-op, leaving `item` as the other concurrent steps produced it,
    /// whenever nothing played this session, it isn't Show content, the server
    /// never confirms `played` within the poll window, or NextUp has nothing or
    /// returns the same episode — all indistinguishable from nothing to advance
    /// to yet.
    private func advanceToNextEpisodeIfCompleted(playedEpisodeID: String?) async {
        guard let playedEpisodeID, let seriesID else { return }

        var confirmedPlayed = false
        for delay in Self.userDataCommitPollSchedule {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let dto = try? await client.item(userID: userID, itemID: playedEpisodeID) else { continue }
            if dto.userData?.played == true {
                confirmedPlayed = true
                break
            }
        }
        guard confirmedPlayed else { return }

        guard let nextDto = try? await client.nextUp(userID: userID, seriesID: seriesID).items.first,
              nextDto.id != playedEpisodeID else { return }

        await selectEpisode(nextDto.id)
        // The guess belonged to the superseded episode. Leaving it set is
        // harmless, since a future `refreshItem()` would never match it again,
        // but clearing avoids it lingering as stale state.
        if optimisticPlaybackTarget?.itemID == playedEpisodeID { optimisticPlaybackTarget = nil }
    }

    /// Resolves `showPlaybackEpisode`, which documents which episode each case
    /// picks. A set `preselectedSeasonID` marks a Season tap's target, scoped to
    /// that season, rather than a Series tap's NextUp. Safe to rely on because
    /// this is only called for Show content — Episode content also sets
    /// `preselectedSeasonID` but never invokes this.
    private func resolveShowPlaybackEpisode(seriesID: String, images: ImageURLBuilder) async {
        if let preselectedSeasonID {
            if let firstEpisodeDto = try? await client.episodes(
                seriesID: seriesID, seasonID: preselectedSeasonID, userID: userID
            ).items.first {
                showPlaybackEpisode = MediaItem(dto: firstEpisodeDto, images: images)
            }
        } else if let nextUpDto = try? await client.nextUp(userID: userID, seriesID: seriesID).items.first {
            showPlaybackEpisode = MediaItem(dto: nextUpDto, images: images)
        } else if let firstSeason = seasons.first,
                  let firstEpisodeDto = try? await client.episodes(
                      seriesID: seriesID, seasonID: firstSeason.id, userID: userID
                  ).items.first {
            showPlaybackEpisode = MediaItem(dto: firstEpisodeDto, images: images)
        }
    }
}
