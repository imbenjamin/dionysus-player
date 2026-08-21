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

    /// What `ShowDetailView`/`MovieDetailView` actually render as the page's
    /// hero/synopsis/metadata/Play button/tabs content. For a Movie (or a
    /// Series tapped directly), this is just the requested item. For a
    /// Season or Episode tapped directly (e.g. a deep link, or an episode
    /// from Home's Continue Watching rail), the *page* is still the Show's —
    /// see `seriesID`/`preselectedSeasonID` below — but `item` itself is
    /// only swapped to the Series' own item for a Season selection; an
    /// Episode selection keeps `item` as that episode, so its own overview/
    /// artwork/technical details/versions are what actually show, matching
    /// what other Jellyfin clients do when you deep-link straight to an
    /// episode. See `load()` for exactly which case does which.
    private(set) var item: MediaItem?
    /// The Show these seasons/episodes belong to — always set alongside
    /// `item` for a Series/Season/Episode load (never for a Movie). Distinct
    /// from `item.id`: `item` can be an Episode's own id while this is its
    /// parent Series' id, which is what `SeasonEpisodeList` and
    /// `showPlaybackEpisode`'s resolution actually need to scope their
    /// fetches.
    private(set) var seriesID: String?
    /// Which season `ShowDetailView`'s season picker should default to,
    /// rather than always the first — the tapped Season itself, or an
    /// Episode's parent season. `nil` for a Series tapped directly (falls
    /// back to the first season, the pre-existing default).
    private(set) var preselectedSeasonID: String?
    private(set) var seasons: [MediaItem] = []
    private(set) var similar: [MediaItem] = []
    private(set) var collections: [MediaItem] = []
    /// A BoxSet's own child items (its movies) — `CollectionDetailView`'s
    /// `CollectionItemList` section. Always empty for every other item
    /// type. Fetched alongside `similar`/`collections` in `load()` (same
    /// non-fatal `try?` treatment — see that method's own doc comment), and
    /// re-fetched at the end of `refreshItem()` so a movie played directly
    /// from the grid (bypassing that movie's own detail page, hence never
    /// going through *its* `refreshItem()`) still shows an up-to-date
    /// watched/progress overlay once the player closes.
    private(set) var collectionItems: [MediaItem] = []
    private(set) var loadState: LoadState = .idle

    /// The Show's own item — always set alongside `seriesID` for a
    /// Series/Season/Episode load, regardless of whether `item` itself is
    /// that same Show (Series/Season case) or a specific Episode (Episode
    /// case, where `item` and `seriesItem` are two genuinely different
    /// items). Exists specifically for `PlayResumeButtonRow`'s favorite/
    /// watched extended menu — the one place that needs the Show's own
    /// status even while `item` is showing an Episode's — see
    /// `ShowDetailView`'s call site. `nil` for a Movie.
    private(set) var seriesItem: MediaItem?

    /// For Show content only (`item.kind == .series`, i.e. a Series tapped
    /// directly or a Season swapped to its parent Series — see `item`'s doc
    /// comment): the specific episode `PlayResumeButtonRow` should target,
    /// resolved once as part of `load()` so the button can show a real
    /// "Play S2:E4"/"Resume S2:E4" label instead of a bare one. `nil` for
    /// Movie/Episode content (where `item` itself is already the thing to
    /// play — `ShowDetailView`'s episode-content branch never reads this),
    /// and briefly `nil` for Show content too until `load()` resolves it.
    ///
    /// Resolution differs by how the page was reached:
    /// - Season tapped directly (`preselectedSeasonID` set): the first
    ///   episode of *that* season specifically — a Season tap reads as
    ///   "start this season", not "continue the show overall".
    /// - Series tapped directly (`preselectedSeasonID` nil): Jellyfin's
    ///   NextUp, which already returns whichever's more relevant — an
    ///   in-progress episode if one exists (so this doubles as "the most
    ///   recently watched part-watched episode" without needing to hunt for
    ///   it across every season ourselves), else the next unwatched one —
    ///   falling back to the first episode of the first season when NextUp
    ///   has nothing at all (a never-started show).
    ///
    /// Either way, `PlayResumeButtonRow` decides Play-vs-Resume purely from
    /// *this resolved episode's own* watched state (via `effectiveItem` —
    /// see that property's doc comment), not any aggregate on the Series/
    /// Season item — which is what makes a Season tap correctly say
    /// "Resume" when its first episode happens to already be part-watched,
    /// rather than always blindly "Play".
    private(set) var showPlaybackEpisode: MediaItem?

    /// The id `refreshItem()` should re-fetch to keep `item` current —
    /// `itemID` itself for a Movie/Series/Episode load (where `item` is
    /// built straight from `itemID`'s own DTO), but the *Series'* id for a
    /// Season load, where `item` was swapped to the Series' DTO instead
    /// of the tapped Season's. Set alongside `item` in `load()`.
    private var displayedItemID: String?

    let itemID: String
    private let client: JellyfinAPIClient
    private let userID: String
    private let versionPreferenceStore: MediaVersionPreferenceStore

    /// Exposed read-only for `DownloadButton`'s call sites
    /// (`MovieDetailView`/`ShowDetailView`), which otherwise only hold this
    /// view model, not a `client`/`userID` of their own — see
    /// `AssetDetailView.init`'s doc comment for why those aren't just read
    /// from `@Environment(AppState.self)` at this layer instead.
    var apiClient: JellyfinAPIClient { client }
    var currentUserID: String { userID }

    /// `preloadedItem` — see `AppRoute.assetDetail`'s doc comment — seeds
    /// `item` immediately so the page has something to render (and a zoom
    /// transition something to land on) before `load()`'s network round
    /// trip resolves. It's necessarily partial (fetched via the rail's
    /// lighter `Fields` list, missing `MediaSources`/`People`), so `load()`
    /// still runs regardless and replaces it with the full item once ready.
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

    /// The version `PlayResumeButtonRow` should silently continue with for a
    /// "Resume" tap on `playableItemID` — whatever was deliberately chosen
    /// the last time that item was started fresh (via the version-choice
    /// prompt), or `nil` to let `PlayerViewModel` fall back to the server's
    /// own default. See `MediaVersionPreferenceStore`'s doc comment for why
    /// this can't just come from the server.
    func preferredMediaSourceID(forPlayableItem playableItemID: String) -> String? {
        versionPreferenceStore.preferredMediaSourceID(forItem: playableItemID, userID: userID)
    }

    /// Records the version-choice prompt's answer so a later "Resume" (see
    /// `preferredMediaSourceID(forPlayableItem:)`) continues the same one.
    func setPreferredMediaSourceID(_ mediaSourceID: String, forPlayableItem playableItemID: String) {
        versionPreferenceStore.setPreferredMediaSourceID(mediaSourceID, forItem: playableItemID, userID: userID)
    }

    /// Guards on `loadState`, not `item` — a preloaded item already makes
    /// `item` non-nil before `load()` has ever run, which would otherwise
    /// make this look like a no-op-needed reload and skip fetching the full
    /// item (cast, technical details, similar/collections rails) entirely.
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)

            // See `item`/`seriesID`/`preselectedSeasonID`/`displayedItemID`'s
            // own doc comments for what each branch below is actually
            // establishing — this is the one place that decides it.
            switch dto.type {
            case .episode:
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                seriesID = dto.seriesId
                preselectedSeasonID = dto.seasonId
                // Unlike the Season case below, `item` here stays the
                // Episode — so the Show's own item (needed for
                // `PlayResumeButtonRow`'s favorite/watched menu — see
                // `seriesItem`'s doc comment) needs its own fetch rather
                // than just reusing `item`.
                if let seriesID, let seriesDTO = try? await client.item(userID: userID, itemID: seriesID) {
                    seriesItem = MediaItem(dto: seriesDTO, images: images)
                }
            case .season:
                if let seriesID = dto.seriesId {
                    // The page's content is the *Show's* own item, not the
                    // Season's (a Season has no overview/artwork/media of
                    // its own worth showing) — so this is the one case
                    // where `displayedItemID` ends up different from
                    // `itemID`.
                    self.seriesID = seriesID
                    preselectedSeasonID = dto.id
                    let seriesDTO = try await client.item(userID: userID, itemID: seriesID)
                    item = MediaItem(dto: seriesDTO, images: images)
                    seriesItem = item
                    displayedItemID = seriesID
                    // `preselectedSeasonID` (just set, above) is what tells
                    // this it's resolving a Season tap's target, not a
                    // Series tap's — see `resolveShowPlaybackEpisode`.
                    await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
                } else {
                    // Shouldn't happen — degrades to showing the Season's
                    // own mostly-empty item rather than crashing.
                    item = MediaItem(dto: dto, images: images)
                    displayedItemID = itemID
                }
            default:
                // Series (the pre-existing path), or a Movie/BoxSet/
                // anything else — none of which have a `seriesID` at all
                // except Series itself, set just below.
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                if dto.type == .series {
                    seriesID = dto.id
                    seriesItem = item
                }
                preselectedSeasonID = nil
            }

            // Similar/collections are scoped to the Show for every
            // Series/Season/Episode case (an episode's own "similar items"
            // via the API is empty/meaningless) — falls back to `itemID`
            // only for a Movie, where there's no Show to scope to at all.
            //
            // All three of these (plus `seasons` below) are `try?`, not
            // `try await` — deliberately: they're supplementary rails, not
            // the page itself, which by this point has already resolved
            // successfully (the primary item fetch above, and the Series
            // item swap-in for a Season tap, are the only fetches this
            // function still lets fail the whole page). A hiccup on
            // `/Similar` or `collectionsContaining`'s BoxSets probe used to
            // take the *entire* page — hero, Play button, everything
            // already loaded fine — down to a full-screen error instead of
            // just leaving that one rail empty, which is what happens now.
            let similarCollectionsID = seriesID ?? itemID
            async let similarResult = try? client.similarItems(itemID: similarCollectionsID, userID: userID)
            async let collectionsResult = try? client.collectionsContaining(itemID: similarCollectionsID, userID: userID)
            // `collectionItems`' own fetch — see that property's doc
            // comment. Scoped to `dto.type == .boxSet` specifically (not
            // just always fetched and thrown away for other kinds), since
            // there's no `ParentId`-scoped child list to fetch for anything
            // else — a Movie/Episode has no children at all, and a Series'
            // are `seasons`, already fetched separately below.
            async let collectionItemsResult: BaseItemDtoQueryResult? = dto.type == .boxSet
                ? try? client.items(userID: userID, parentID: itemID, recursive: false, sortBy: "PremiereDate")
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

            loadState = .loaded
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't load this title.")
            )
        }
    }

    /// Switches this Show-content page's displayed content to `episodeID`
    /// in place — tapping the text area of an episode row in
    /// `SeasonEpisodeList` (as opposed to its play button, which plays that
    /// episode directly without changing what this page shows), and also
    /// `advanceToNextEpisodeIfCompleted()`'s own way of performing its swap
    /// once a next episode is confirmed. Fetches the episode's *full* item
    /// (technical details/versions/cast — unlike the lighter list-fetch
    /// `SeasonEpisodeList` itself already has), then swaps
    /// `item`/`displayedItemID` to it — the exact same shape a direct
    /// Episode tap already produces (see `item`'s doc comment), so
    /// everything downstream (`PlayResumeButtonRow`'s `isEpisodeContent`
    /// branch, `DetailTabsView`, the episode list's own highlighted row)
    /// just follows `item` reactively with no special-casing needed here.
    /// Deliberately doesn't touch `seriesID`/`seasons` — the episode is
    /// always within the same Show. Does keep `preselectedSeasonID`
    /// current, though (unlike `seriesID`/`seasons`): harmless for this
    /// method's original caller (`SeasonEpisodeList.onSelectEpisode` can
    /// only ever pick an episode from whichever season is already
    /// selected, so this is a same-value reassignment there), but load-
    /// bearing for `advanceToNextEpisodeIfCompleted()`, which can cross a
    /// season boundary — `ShowDetailView`'s own `.onChange(of:
    /// viewModel.item?.id)` is what keeps its season picker following this.
    func selectEpisode(_ episodeID: String) async {
        guard let dto = try? await client.item(userID: userID, itemID: episodeID) else { return }
        let images = await client.makeImageURLBuilder()
        item = MediaItem(dto: dto, images: images)
        displayedItemID = episodeID
        preselectedSeasonID = dto.seasonId
    }

    /// Which items currently have a favorite toggle in flight — checked by
    /// `HeroActionButtons` to show a spinner in place of the star icon
    /// rather than leaving the button looking inert while the request (and
    /// the confirmation re-fetch below) are in progress, which can
    /// genuinely take a couple of seconds. Keyed by item id rather than a
    /// single flag since a Show-content page's menu can have the Show,
    /// Season, and Episode each toggling independently. See
    /// `pendingWatchedIDs` for the same thing on the watched side.
    private(set) var pendingFavoriteIDs: Set<String> = []
    /// See `pendingFavoriteIDs` — identical shape, watched status instead.
    private(set) var pendingWatchedIDs: Set<String> = []

    /// Looks up `itemID`'s live favorite/watched status from whichever of
    /// `item`/`seriesItem`/`showPlaybackEpisode`/`seasons` currently holds
    /// it — the same set of targets `applyOptimisticFavoriteWatched` and
    /// `refetchFavoriteWatchedTarget` patch. `HeroActionButtons` calls this
    /// right when a toggle actually fires, rather than trusting the
    /// `MediaItem` its own button/menu-row closure captured, however
    /// recently that closure was constructed.
    ///
    /// Exists because of a real, confirmed-live (2026-08-16) SwiftUI toolbar
    /// bug: `HeroActionButtons` is hosted as a `ToolbarItem`, and while its
    /// *displayed* icon reliably tracks `item`/`seriesItem` reactively (see
    /// `MovieDetailView`'s own doc comment on this), the `Button`/`Menu` row
    /// *action* closures underneath it can keep firing with the `MediaItem`
    /// snapshot captured the *first* time that toolbar content was built —
    /// not the latest one — even many renders and toggles later. Confirmed
    /// directly: tapping Favorite, waiting for it to fully confirm (icon
    /// visibly updates), then tapping it again read the second tap's
    /// `currentlyFavorite` as the value from *before the first tap*, so the
    /// second write silently repeated the first instead of reversing it —
    /// exactly the reported "second press looks like it does nothing" bug.
    /// Routing the lookup through `viewModel` (a stable reference the whole
    /// page keeps one instance of) rather than through the closure's own
    /// captured value sidesteps the staleness regardless of how out of date
    /// that closure is: `viewModel.item` etc. are read fresh here, every
    /// call. Falls back to the caller's own belief if `itemID` doesn't match
    /// anything currently held (shouldn't happen in practice — every
    /// favorite/watched target offered in the UI comes from one of these
    /// four properties).
    func currentFavoriteWatchedStatus(forItemID itemID: String) -> (favorite: Bool, watched: Bool)? {
        if let item, item.id == itemID { return (item.isFavorite, item.isPlayed) }
        if let seriesItem, seriesItem.id == itemID { return (seriesItem.isFavorite, seriesItem.isPlayed) }
        if let showPlaybackEpisode, showPlaybackEpisode.id == itemID {
            return (showPlaybackEpisode.isFavorite, showPlaybackEpisode.isPlayed)
        }
        if let season = seasons.first(where: { $0.id == itemID }) { return (season.isFavorite, season.isPlayed) }
        return nil
    }

    /// Fire-and-forget `Task`s wrapping this view model's own async methods
    /// (`toggleFavorite`/`toggleWatched`/`refreshItem`), registered here by
    /// their call sites (`HeroActionButtons`, `MovieDetailView`/
    /// `ShowDetailView`) via `track(_:)` right after creating each one.
    /// `cancelBackgroundWork()` — `AssetDetailView`'s own `.onDisappear` —
    /// is what actually stops them once this page is no longer on screen,
    /// instead of a favorite toggle's confirmation poll or a post-playback
    /// refresh (both up to ~13s — `userDataCommitPollSchedule`) running to
    /// completion regardless, issuing network requests against a screen nobody's
    /// looking at anymore. The methods themselves stay plain `async`
    /// functions any caller (including tests) can `await` directly —
    /// only real UI call sites need to route through `track(_:)` at all.
    private var backgroundTasks: [Task<Void, Never>] = []

    /// See `backgroundTasks`'s doc comment.
    func track(_ task: Task<Void, Never>) {
        backgroundTasks.append(task)
    }

    /// See `backgroundTasks`'s doc comment. Safe to call even with nothing
    /// in flight — cancelling an already-finished `Task` is a no-op.
    func cancelBackgroundWork() {
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
    }

    /// Shared by `refetchFavoriteWatchedTarget`/`refreshItem()`: Jellyfin's
    /// write endpoints (`setFavorite`/`setWatched`, and — for `refreshItem()`
    /// — whatever `/Sessions/Playing/Stopped` triggers server-side) return
    /// 200 immediately but commit the actual userData change asynchronously
    /// afterward, with *genuinely variable* latency. Confirmed live,
    /// direct-to-server `curl` checks against this same server: toggling a
    /// Movie or Episode's favorite status is reliably confirmable well under
    /// a second, but toggling a Series' (a Show's own, not a Season/
    /// Episode's) sometimes confirms just as fast and other times took
    /// several seconds longer than that, on the exact same item with no code
    /// change in between.
    ///
    /// `refreshItem()` used to poll on a much shorter schedule of its own
    /// (~3.25s total) — reproduced live (2026-08-13) that it wasn't enough
    /// for at least one real case: resuming a movie, scrubbing to a
    /// different position, and exiting within a few seconds. The scrub
    /// itself never reaches the server at all (playback progress only
    /// reports every 10s while playing — see `PlayerViewModel
    /// .startProgressReporting()` — so a short session's *only* report is
    /// the final stop), and confirmed that write did land correctly
    /// (resuming again afterward picked up the right position) — just not
    /// within `refreshItem()`'s old, shorter poll window, leaving the
    /// detail page's progress bar showing the pre-scrub position even
    /// though the server already had the right one. Sharing this longer,
    /// already-proven-sufficient schedule (rather than tuning a second,
    /// shorter one and hoping) is the fix.
    private static let userDataCommitPollSchedule: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

    /// Toggles `itemID`'s favorite status (`HeroActionButtons`' button/
    /// menu — `itemID` is always `item.id` on a Movie/Episode-content page,
    /// but can be the Show's, the currently-selected Season's, or the
    /// current Episode's id on a Show-content page, per that view's own
    /// three-way menu). `currentlyFavorite` is whatever the caller already
    /// has on hand for that same item — this doesn't re-derive it, just
    /// flips it.
    func toggleFavorite(itemID: String, currentlyFavorite: Bool) async {
        pendingFavoriteIDs.insert(itemID)
        defer { pendingFavoriteIDs.remove(itemID) }
        let newValue = !currentlyFavorite
        let succeeded = (try? await client.setFavorite(newValue, itemID: itemID, userID: userID)) != nil
        // See `applyOptimisticFavoriteWatched(itemID:favorite:watched:)`'s
        // doc comment for why this can't just wait on the confirmation poll
        // below — only applied once the write itself has actually
        // succeeded, so a genuinely failed request doesn't show a false
        // "it worked" state.
        if succeeded { applyOptimisticFavoriteWatched(itemID: itemID, favorite: newValue) }
        await refetchFavoriteWatchedTarget(itemID: itemID, expectedFavorite: newValue)
    }

    /// See `toggleFavorite(itemID:currentlyFavorite:)` — identical shape,
    /// for Jellyfin's separate "watched" status instead.
    func toggleWatched(itemID: String, currentlyWatched: Bool) async {
        pendingWatchedIDs.insert(itemID)
        defer { pendingWatchedIDs.remove(itemID) }
        let newValue = !currentlyWatched
        let succeeded = (try? await client.setWatched(newValue, itemID: itemID, userID: userID)) != nil
        if succeeded { applyOptimisticFavoriteWatched(itemID: itemID, watched: newValue) }
        await refetchFavoriteWatchedTarget(itemID: itemID, expectedWatched: newValue)
    }

    /// Immediately reflects a just-succeeded `setFavorite`/`setWatched`
    /// write on whichever of `item`/`seriesItem`/`showPlaybackEpisode`/
    /// `seasons` currently holds `itemID` — the same set of targets
    /// `refetchFavoriteWatchedTarget` patches once the server actually
    /// confirms the change, and the same "reflect a known-correct value
    /// immediately rather than waiting on a round trip" shape as
    /// `applyOptimisticPlaybackPosition(_:)` above.
    ///
    /// Exists because that confirmation can take far longer than
    /// `userDataCommitPollSchedule` waits out — confirmed live (2026-08-16):
    /// a movie's favorite write returned success immediately (per Jellyfin's
    /// documented behavior — see that property's own doc comment), but
    /// didn't actually commit server-side for several *minutes* on a real
    /// server, an order of magnitude past the poll's ~13s budget. Without
    /// this, `refetchFavoriteWatchedTarget`'s poll kept re-fetching the
    /// still-stale (pre-write) value and patching it straight into `item`
    /// on every attempt, so by the time the poll gave up, the button looked
    /// exactly like tapping it had done nothing at all — the reported bug
    /// this fixes. `refetchFavoriteWatchedTarget` itself no longer adopts an
    /// unconfirmed fetch (see its own doc comment), so once this has run,
    /// nothing downstream can regress it back to that stale value while the
    /// real commit is still in flight.
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

    /// Shared by `toggleFavorite`/`toggleWatched`: re-fetches whichever item
    /// was just toggled and patches it into every property that might be
    /// holding a now-stale copy of it — `item` and `seriesItem` are each
    /// exactly one item so a simple id match suffices; `seasons` and
    /// `showPlaybackEpisode` are checked the same way. A toggle can target
    /// any of these independently (see `toggleFavorite`'s doc comment), and
    /// more than one can legitimately match at once (e.g. toggling the
    /// Series' own favorite status when `item` *is* that Series updates
    /// both `item` and `seriesItem` together, since they're the same id).
    ///
    /// Polls on a short/growing schedule, for the same reason `refreshItem()`
    /// below does — see `userDataCommitPollSchedule`'s own doc comment for
    /// the shared reasoning/schedule both use.
    ///
    /// `expectedFavorite`/`expectedWatched` (whichever this call is
    /// toggling — the other stays `nil` and is ignored) is what this polls
    /// *for*: keep re-fetching until the server actually reports the value
    /// this just wrote, not just any response.
    private func refetchFavoriteWatchedTarget(itemID: String, expectedFavorite: Bool? = nil, expectedWatched: Bool? = nil) async {
        let images = await client.makeImageURLBuilder()
        for delay in Self.userDataCommitPollSchedule {
            try? await Task.sleep(for: .seconds(delay))
            // `Task.sleep` throwing on cancellation is swallowed by `try?`
            // above, so this is what actually stops the poll early once
            // `cancelBackgroundWork()` (`AssetDetailView`'s `.onDisappear`)
            // cancels the `Task` this is running in — otherwise a page
            // backed out of mid-toggle would keep polling for the rest of
            // the schedule against a screen nobody's looking at.
            guard !Task.isCancelled else { return }
            guard let dto = try? await client.item(userID: userID, itemID: itemID) else { continue }
            let updated = MediaItem(dto: dto, images: images)
            let favoriteConfirmed = expectedFavorite.map { $0 == updated.isFavorite } ?? true
            let watchedConfirmed = expectedWatched.map { $0 == updated.isPlayed } ?? true
            // Not confirmed yet — this fetch is almost certainly just the
            // server's still-uncommitted old value (see
            // `applyOptimisticFavoriteWatched`'s doc comment for why that
            // commit can take far longer than this whole poll schedule).
            // Adopting it here would regress `item`/etc. straight back to
            // that stale value, undoing the optimistic update the toggle
            // already applied — skip it and try again next attempt instead,
            // exactly like `refreshItem()`'s own `optimisticTarget` guard
            // just below.
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
    /// Also records `optimisticPlaybackTarget` — see that property's own doc
    /// comment for why `refreshItem()` needs it: without it, the very poll
    /// this method is meant to be ahead of ends up undoing it (reproduced
    /// live, 2026-08-13 — this method alone wasn't sufficient by itself).
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
    }

    /// Set by `applyOptimisticPlaybackPosition(_:)`, read (and cleared) by
    /// `refreshItem()` — the fix for a real bug in how those two interact.
    ///
    /// `refreshItem()`'s poll normally stops as soon as a fetch *differs*
    /// from whatever `item` held when the poll started — a reasonable way
    /// to detect "the server has caught up" in general. But by the time it
    /// starts, `item` already holds *this session's own optimistic guess*
    /// (applied by `applyOptimisticPlaybackPosition(_:)` moments earlier,
    /// from the same close-and-return flow) — not the server's last-known
    /// value. Reproduced live (2026-08-13): the poll's first attempt, ~0.25s
    /// in, almost always still gets the server's *old*, not-yet-committed
    /// position back — which "differs" from the optimistic guess just fine,
    /// so the poll adopted it and stopped immediately, silently overwriting
    /// the correct guess with stale data and never trying again.
    ///
    /// The fix: while this is set, `refreshItem()` ignores any fetch that
    /// hasn't actually caught up to it yet (within `optimisticPositionTolerance`
    /// — an exact match isn't realistic; see that property's own doc
    /// comment) rather than adopting whatever it happens to get back first,
    /// unless the server's independently decided the item is fully played
    /// (which resets its position on its own schedule, so it would never
    /// "catch up" to a pre-played guess otherwise). Scoped by itemID rather
    /// than just cleared on every call: `refreshItem()`'s own `displayedItemID`
    /// only ever concerns `item`, never `showPlaybackEpisode`, so a guess
    /// that belongs to the latter must be left alone rather than compared
    /// against fetches for the former.
    private var optimisticPlaybackTarget: (itemID: String, ticks: Int64)?

    /// How close a poll's fetched `playbackPositionTicks` needs to be to
    /// `optimisticPlaybackTarget`'s guess to count as "caught up" — not an
    /// exact match, since the guess and the value `PlayerViewModel.stop()`
    /// actually reports are read from the engine's clock a moment apart
    /// (whatever plays out between `PlayerView.close()` capturing this
    /// session's outcome and its own later call to `stop()`), so they can
    /// differ by up to a couple of real seconds even once the server has
    /// genuinely committed the right write. 5 real seconds (in ticks, 100ns
    /// units) comfortably covers that drift while still clearly rejecting
    /// the *actually* stale case this exists for — a resume position tens of
    /// minutes off from a scrub.
    private static let optimisticPositionTolerance: Int64 = 5 * 10_000_000

    /// Bumped once at the end of every `refreshItem()` call — `SeasonEpisodeList`
    /// takes this as a prop and folds it into its own episode-list `.task(id:)`,
    /// so returning from a playback session re-fetches that season's episode
    /// rows too (each row's own progress bar/watched state — see
    /// `EpisodeRow` — otherwise stayed stale until a manual season-picker
    /// change, since that list fetches independently of `item`). A plain
    /// `UUID`, not a `Bool`/counter: `SeasonEpisodeList`'s `.task(id:)` only
    /// needs *some* distinct, `Equatable` value each time to force a re-run,
    /// not anything with meaning of its own.
    private(set) var episodeListRefreshToken = UUID()

    /// Re-fetches just the main item's DTO so the Play/Resume button and its
    /// progress bar reflect the latest server-side watch state (e.g. after
    /// returning from the player) — see `episodeListRefreshToken` just above
    /// for the sibling episode list. Skips `seasons`/`similar`/`collections`
    /// — those genuinely don't change from one playback session.
    ///
    /// Polls on `userDataCommitPollSchedule` — see that property's own doc
    /// comment for why, including this specific method's own history with
    /// getting that schedule's length wrong — until the returned userData
    /// actually differs from what we had (which means the server has caught
    /// up), or we hit the last attempt.
    func refreshItem() async {
        // `displayedItemID`, not `itemID` — see that property's doc comment.
        // They're the same value except for a Season load, where `item` was
        // swapped to the Show's own DTO; re-fetching `itemID` there would
        // overwrite `item` with the tapped Season's DTO instead.
        guard let displayedItemID else { return }
        let previousTicks = item?.dto.userData?.playbackPositionTicks
        let previousPercentage = item?.dto.userData?.playedPercentage
        let previouslyPlayed = item?.dto.userData?.played
        // See `optimisticPlaybackTarget`'s own doc comment — only relevant
        // when it belongs to `item` specifically (`displayedItemID`), not a
        // `showPlaybackEpisode` guess this fetch has nothing to do with.
        let optimisticTarget = optimisticPlaybackTarget?.itemID == displayedItemID ? optimisticPlaybackTarget : nil
        // Captured up front, before either task below can reassign `item` —
        // see `refreshShowPlaybackEpisodeIfNeeded`'s doc comment for why
        // this can't just re-read `item?.kind` after the poll instead.
        let isShowContent = item?.kind == .series
        // Also captured up front rather than read from inside
        // `advanceToNextEpisodeIfCompleted` — see that method's own doc
        // comment for the race this avoids.
        let playedEpisodeID = optimisticPlaybackTarget?.itemID
        let images = await client.makeImageURLBuilder()

        // Both run concurrently, not sequentially — see
        // `refreshShowPlaybackEpisodeIfNeeded`'s and
        // `advanceToNextEpisodeIfCompleted`'s own doc comments for why
        // gating either behind the poll below (the original shape) left
        // them waiting up to the poll's *entire* schedule for Show content.
        async let showPlaybackEpisodeUpdate: Void = refreshShowPlaybackEpisodeIfNeeded(isShowContent: isShowContent, images: images)
        async let nextEpisodeAdvance: Void = advanceToNextEpisodeIfCompleted(playedEpisodeID: playedEpisodeID)

        for delay in Self.userDataCommitPollSchedule {
            try? await Task.sleep(for: .seconds(delay))
            // See the matching check in `refetchFavoriteWatchedTarget` —
            // same reasoning, same reliance on `cancelBackgroundWork()`.
            guard !Task.isCancelled else { return }
            guard let dto = try? await client.item(userID: userID, itemID: displayedItemID) else { continue }

            // `advanceToNextEpisodeIfCompleted`, running concurrently
            // above, can swap `self.displayedItemID` out from under this
            // loop mid-poll (to a *different* episode entirely) — if that's
            // already happened, this fetch (for the now-superseded item)
            // is stale; adopting it would clobber the advance right back
            // to the episode the user just finished. Stop rather than risk
            // that — the advance has already produced the more current,
            // correct state, so there's nothing more for this poll to do.
            guard self.displayedItemID == displayedItemID else { break }

            if let optimisticTarget {
                let fetchedTicks = dto.userData?.playbackPositionTicks ?? 0
                let played = dto.userData?.played ?? false
                let caughtUp = fetchedTicks >= optimisticTarget.ticks - Self.optimisticPositionTolerance || played
                // Not caught up yet — this fetch is almost certainly just
                // the server's old, not-yet-committed value; adopting it
                // would regress `item` back to stale data (the exact bug
                // this whole property exists to fix), so skip it and try
                // again next attempt instead.
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

        // `collectionItems`' own refresh — see that property's doc comment
        // for why this needs its own re-fetch (a movie played directly from
        // the grid never goes through its own `refreshItem()`). Placed
        // after the polling loop above rather than run concurrently with
        // it like `showPlaybackEpisodeUpdate`/`nextEpisodeAdvance` are —
        // deliberately: this page's own `displayedItemID` poll never
        // "catches up" for a BoxSet (its own `userData` has nothing to do
        // with any one child's progress), so that loop harmlessly runs its
        // entire schedule regardless, which incidentally buys enough real
        // time for the played child's own userData commit to have already
        // landed by the time this fires — same latency `userDataCommitPollSchedule`
        // exists to wait out elsewhere, just piggybacked here rather than
        // polled separately.
        if item?.kind == .boxSet, let childrenResult = try? await client.items(
            userID: userID, parentID: displayedItemID, recursive: false, sortBy: "PremiereDate"
        ) {
            collectionItems = childrenResult.items.map { MediaItem(dto: $0, images: images) }
        }

        // See `episodeListRefreshToken`'s own doc comment. Bumped
        // unconditionally (not just when the polling loop above actually
        // detected a change) — `SeasonEpisodeList`'s own fetch is a single
        // shot, not polled, so there's no "did this change" check to gate
        // it on here either; a harmless extra fetch of the same data is the
        // worst case when nothing changed (e.g. this page's currently
        // selected season isn't the one that was just played from).
        episodeListRefreshToken = UUID()
    }

    /// `refreshItem()`'s Show-content counterpart to its own item poll —
    /// pulled out into its own function specifically so it can run
    /// *concurrently* with that poll via `async let`, rather than after it.
    ///
    /// The original shape ran this sequentially, gated behind the poll
    /// loop finishing (whether by detecting a change or exhausting its
    /// schedule). That's fine for a Movie/Episode-content page, where the
    /// poll and this update are the same thing — but for Show content
    /// (`isShowContent`, i.e. `item` is the Series' own DTO) they're
    /// polling *different* things: the loop watches the Series' own
    /// `userData`, which essentially never reflects a single episode's
    /// progress, so its "did this change?" exit condition almost never
    /// fires — confirmed live (2026-08-13): a real playback session's poll
    /// exhausted its entire ~13s schedule every time, with this call only
    /// running (and `showPlaybackEpisode` only updating) *after* that,
    /// regardless of how quickly the server actually committed the
    /// episode's own new state. Running the two concurrently means this
    /// starts immediately instead of waiting on an unrelated, near-certain
    /// no-op.
    ///
    /// `isShowContent` is a parameter (`item?.kind == .series`, captured by
    /// the caller *before* either task starts) rather than read directly
    /// here, since by the time an `async let`-scheduled call to this
    /// actually runs, the poll may already have reassigned `item` — for a
    /// Series load `item` stays a Series throughout so this wouldn't
    /// currently change the answer, but reading a value that's concurrently
    /// being mutated elsewhere, when the correct one is trivially available
    /// up front, is worth avoiding on principle.
    private func refreshShowPlaybackEpisodeIfNeeded(isShowContent: Bool, images: ImageURLBuilder) async {
        guard isShowContent, let seriesID else { return }
        await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
    }

    /// After a playback session closes, checks whether the episode that was
    /// actually playing (`playedEpisodeID` — `optimisticPlaybackTarget`'s
    /// itemID at the time `refreshItem()` started; see
    /// `applyOptimisticPlaybackPosition(_:)`'s doc comment, which sets it
    /// regardless of whether this page started out as Show-direct content
    /// or Episode content) is now fully watched, and if Jellyfin's own
    /// NextUp resolves to a *different* episode, advances this page to show
    /// it — reusing `selectEpisode(_:)`'s existing fetch-and-swap shape (and
    /// its `preselectedSeasonID` update, for `ShowDetailView`'s season
    /// picker to follow across a season boundary).
    ///
    /// A Show-direct page becomes an Episode-content page this way — by
    /// design, not a special case: `isEpisodeContent` (`ShowDetailView`'s
    /// own name for this) is purely `item?.kind == .episode`, so once
    /// `item` swaps to the resolved next episode, the page's existing
    /// Episode-content rendering just takes over, with no new branching
    /// needed anywhere in the view layer.
    ///
    /// Deliberately its own poll, not folded into the `displayedItemID`
    /// poll in `refreshItem()`: for a Show-direct page, the episode that
    /// played and `displayedItemID` (the Series' own id) are two different
    /// items entirely — that poll fetches the Series' own DTO, which can't
    /// answer "is *this episode* played" at all. Runs concurrently with
    /// that poll (`async let` in `refreshItem()`) for the same reason
    /// `refreshShowPlaybackEpisodeIfNeeded` does — gating this behind an
    /// unrelated poll's full schedule would delay it for no reason. Because
    /// it can end up mutating `item`/`displayedItemID` itself (via
    /// `selectEpisode`) while that other poll is still running, `refreshItem()`'s
    /// own loop has a matching guard to avoid the two racing — see the
    /// comment at its `self.displayedItemID == displayedItemID` check.
    ///
    /// Confirmed live (2026-08-13) against a real server for the
    /// Show-direct entry point specifically: a page showing "Play S2:E2"
    /// finished that episode and landed on "Play S2:E3" — a real
    /// Series-direct-to-Episode-content transition, poll confirming
    /// `played` on its very first attempt. Also separately confirmed live
    /// crossing an actual season boundary (finishing a season's last
    /// episode correctly landed on the next season's first, with the
    /// season picker following — see `preselectedSeasonID`'s update below
    /// and `ShowDetailView`'s matching `.onChange`). The Episode-content
    /// entry point (starting already on a specific episode's own page)
    /// exercises the identical code path and is covered by
    /// `test_refreshItem_episodeContent_confirmedPlayed_advancesToNextEpisode`,
    /// but wasn't separately live-confirmed with a real full-episode
    /// completion — only with a partial watch (which correctly didn't
    /// advance).
    ///
    /// No-ops (leaves `item` exactly as whatever the other concurrent steps
    /// already produced) whenever: nothing was actually played this session
    /// (`playedEpisodeID` nil), it wasn't Show content (no `seriesID`), the
    /// server never confirms `played` within the poll window, or NextUp has
    /// nothing (series finished) or returns the same episode again — all
    /// indistinguishable from "nothing to advance to yet," which is the
    /// correct, safe fallback in every case rather than guessing.
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
        // The guess this was tracking belonged to the now-superseded
        // episode — leaving it set is harmless (a future `refreshItem()`'s
        // own itemID-matching would just never match it again), but
        // clearing it here is tidier and avoids it lingering as stale state.
        if optimisticPlaybackTarget?.itemID == playedEpisodeID { optimisticPlaybackTarget = nil }
    }

    /// Resolves `showPlaybackEpisode` — see that property's doc comment for
    /// exactly which episode each case picks. `preselectedSeasonID` being
    /// set is what tells this it's resolving a *Season* tap's target
    /// (scoped to that one season) rather than a *Series* tap's (NextUp,
    /// falling back to the first episode of the first season) — safe to
    /// rely on here because this is only ever called for Show content
    /// (`load()`'s `.season` case and its post-`seasons` `.series` case;
    /// `refreshShowPlaybackEpisodeIfNeeded`'s `isShowContent` guard), never
    /// for Episode content, where `preselectedSeasonID` is *also* set (to
    /// that episode's own season) but this function is simply never invoked.
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
