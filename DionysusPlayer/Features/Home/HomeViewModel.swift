import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A random mix of unwatched movies/series for the hero rail at the top
    /// of Home. Reshuffles (server-side, via `SortBy=Random`) on every
    /// `load()`/`hardRefresh()`.
    private(set) var heroItems: [MediaItem] = []
    /// The user's own libraries (Movies, Shows, Collections, ...), for the
    /// rail that replaced the old top-menu category picker.
    private(set) var libraries: [MediaItem] = []
    /// Continue Watching, Next Up, Recently Added Movies, Recently Added
    /// Shows, in that order — omitted when empty. Kept separate from
    /// `dynamicRails` (rather than one flat array, as this used to be) so
    /// `softRefresh()` has a precise, safe target to replace in place
    /// without touching dynamic rails or their scroll-triggered pagination
    /// state.
    private(set) var curatedRails: [MediaCollectionRail] = []
    /// However many dynamic rails (genres, studios/networks, actors,
    /// directors — see `DynamicRailCandidate`) have loaded so far via
    /// `loadDynamicRailCandidates`/`loadMoreDynamicRails`.
    private(set) var dynamicRails: [MediaCollectionRail] = []
    /// `HomeView` renders this straight through as one list — the split
    /// above only matters internally, for `softRefresh()`/`hardRefresh()`
    /// to target the right slice.
    var rails: [MediaCollectionRail] { curatedRails + dynamicRails }
    private(set) var loadState: LoadState = .idle

    /// Dynamic rail candidates discovered but not yet fetched into a rail —
    /// see `loadDynamicRailCandidates`. Drawn down from the front in
    /// batches of `dynamicRailBatchSize` by `loadMoreDynamicRails`, so Home
    /// never pays the cost of fetching every possible dynamic rail up
    /// front, only however many the user actually scrolls to.
    private var pendingDynamicRailCandidates: [DynamicRailCandidate] = []
    /// Whether `pendingDynamicRailCandidates` still has more to draw from —
    /// `HomeView` shows its scroll-triggered "load more" sentinel exactly
    /// while this is true, so it disappears once every candidate has been
    /// drawn rather than continuing to trigger empty loads.
    private(set) var hasMoreDynamicRails = false
    /// Drives `HomeView`'s loading indicator at the bottom of the rail
    /// list, and guards `loadMoreDynamicRails` against firing a second
    /// overlapping batch if the sentinel re-appears before the first
    /// finishes (e.g. a fast scroll).
    private(set) var isLoadingMoreDynamicRails = false
    /// Set when the *last* `loadDynamicRailCandidates()` attempt had at
    /// least one of its six fetches throw (typically a connectivity blip
    /// right after the app reconnects) — distinct from `pendingDynamicRailCandidates`
    /// legitimately ending up empty because the library just has nothing
    /// to offer. `HomeView` uses this to know whether a later "we're back
    /// online" transition is worth retrying at all; see
    /// `retryDynamicRailCandidatesIfNeeded()`.
    private(set) var dynamicRailCandidatesFailed = false
    /// Every candidate that has already turned into a visible rail —
    /// populated by `loadMoreDynamicRails()`, consulted by
    /// `loadDynamicRailCandidates()` so a retry after a partial failure
    /// (see `retryDynamicRailCandidatesIfNeeded()`) can't requeue and
    /// re-append a rail that's already showing. Candidates that failed
    /// `minimumDynamicRailItemCount` are deliberately *not* tracked here —
    /// retrying those is harmless, they'll either fail the bar again or
    /// (if the library changed in the meantime) correctly succeed.
    private var consumedDynamicRailCandidates: Set<DynamicRailCandidate> = []

    /// Kept small — each batch fires `dynamicRailBatchSize` concurrent rail
    /// fetches and then appends all of them to `rails` in one state update,
    /// landing right as `HomeView`'s scroll-triggered sentinel fires (i.e.
    /// while the user is actively scrolling through exactly that region).
    /// Brought down from 10: a batch that size meant up to 10 new rail
    /// sections' worth of network fetches and first-page image loads
    /// landing on the main thread in one shot, a plausible contributor to
    /// an intermittently-reported real-device freeze scrolling into the
    /// dynamic rails. 5 halves that burst per batch — still few enough
    /// scroll-triggered reloads that it doesn't meaningfully change how
    /// often `loadMoreDynamicRails` fires overall.
    /// Resolved once by `load()`/`hardRefresh()`, reused by both the
    /// curated rails' own `seeAllQuery`s and (via `DynamicRailCandidate
    /// .seeAllQuery`) `loadMoreDynamicRails`' — stored rather than a
    /// `performFullLoad()`-local `let` since `loadMoreDynamicRails` is also
    /// called independently later, from `HomeView`'s scroll-triggered
    /// sentinel, long after `performFullLoad()`'s own locals are out of
    /// scope.
    private var moviesLibraryID: String?
    private var showsLibraryID: String?

    private static let dynamicRailBatchSize = 5
    /// A dynamic rail candidate needs at least this many items to become a
    /// rail — Jellyfin's `/Items` endpoint has no "minimum result count"
    /// query param to push this into the request itself, so it's a
    /// post-fetch check instead. That's not a compromise: `loadMoreDynamicRails`
    /// already fetches up to `Limit: 16` per candidate, so the returned
    /// array's actual count is a fully reliable measure of real
    /// availability (bounded by that cap) — no second request needed to
    /// know whether a candidate clears the bar.
    private static let minimumDynamicRailItemCount = 5
    /// Caps the `/Persons` discovery calls below — unlike genres/studios
    /// (naturally a few dozen at most), a library's full cast/crew corpus
    /// can run into the thousands, each a full `BaseItemDto`, fetched fresh
    /// on every Home load just to seed rail *candidates*. 200 leaves plenty
    /// of candidates for a typical library (the whole list is shuffled
    /// anyway, so which 200 doesn't need to be exhaustive) while keeping
    /// the discovery payload bounded for a very large one.
    private static let personDiscoveryLimit = 200
    /// Default delays before each reconnect retry of `load()` after a
    /// `ConnectivityMonitor` offline→online transition still finds
    /// `loadState` unloaded — same array-of-delays convention as
    /// `JellyfinAPIClient.reauthBackoffSchedule`/`AssetDetailViewModel
    /// .userDataCommitPollSchedule`. The first attempt is immediate; these
    /// are the delays *before* each subsequent one. Bounded rather than
    /// infinite: a genuinely still-unreachable server must still leave
    /// `loadState` at `.failed` (so the visible "Try Again" button still
    /// works) rather than retrying forever — see `retryLoadIfNeeded()`.
    ///
    /// Deliberately just one retry, not several: unlike
    /// `reauthBackoffSchedule` (a 401 means the server already responded,
    /// so each retry is a normal fast round trip), a *reconnect* retry can
    /// hit a server that's routable but not actually answering — each such
    /// attempt costs up to `JellyfinAPIClient`'s own 20s per-request
    /// timeout before it gives up, not a quick failure. A longer schedule
    /// (originally 4 retries) multiplies that 20s ceiling by every attempt,
    /// which measured live (2026-08-29) as up to ~100s of an unmoving
    /// spinner before finally settling back to the offline screen — far
    /// past what "attempted, then stop" reads as to someone watching it.
    /// One retry bounds the worst case to roughly 2×20s+2s instead, while
    /// still catching the original motivating case (Wi-Fi reassociating a
    /// couple of seconds before the server is actually reachable) with the
    /// first, immediate attempt or this one retry.
    static let defaultReconnectRetrySchedule: [Double] = [2.0]

    private let client: JellyfinAPIClient
    private let userID: String
    /// Injected so tests can pin the "random" order deterministically (an
    /// identity closure) instead of a real shuffle. Defaults to a real
    /// shuffle for production use — every `load()` reshuffles, so the
    /// dynamic rails' order differs each time Home is freshly loaded.
    private let shuffle: ([DynamicRailCandidate]) -> [DynamicRailCandidate]
    /// Same idea as `shuffle` above, but for a dynamic rail's own *items*
    /// rather than which rails appear — see `loadMoreDynamicRails`'s doc
    /// comment for why this is a client-side shuffle rather than the
    /// server's own `SortBy=Random`. `@Sendable`, unlike `shuffle` above —
    /// this one gets called from inside `loadMoreDynamicRails`'s
    /// `withTaskGroup` child tasks, not straight from the actor.
    private let itemShuffle: @Sendable ([BaseItemDto]) -> [BaseItemDto]
    /// See `defaultReconnectRetrySchedule`'s doc comment. Injectable so
    /// tests can exercise `retryLoadIfNeeded()`'s retry/give-up logic
    /// without waiting out the real delays.
    private let reconnectRetrySchedule: [Double]
    /// Coalesces concurrent `retryLoadIfNeeded()` callers into one shared
    /// attempt — see that method's own doc comment for the bug this fixes.
    /// Same shape as `JellyfinAPIClient.inFlightReauth`.
    private var inFlightRetry: Task<Void, Never>?
    /// Bumped once at the top of every `performFullLoad(resetLoadState:)` —
    /// lets `softRefresh()` detect a concurrent `hardRefresh()` that
    /// started (or even finished) after it began and defer to that
    /// instead, see `performSoftRefresh()`'s doc comment.
    private var refreshGeneration = 0
    /// Coalesces concurrent `softRefresh()` callers — same idea as
    /// `inFlightRetry`.
    private var inFlightSoftRefresh: Task<Void, Never>?
    /// Coalesces concurrent `hardRefresh()` callers — same idea as
    /// `inFlightRetry`.
    private var inFlightHardRefresh: Task<Void, Never>?
    /// Drives the VoiceOver-only refresh button's spinner/disabled state in
    /// `HomeView` — `hardRefresh()`'s only user-visible signal, since
    /// `loadState` deliberately doesn't change during one (see
    /// `performFullLoad(resetLoadState:)`'s doc comment).
    private(set) var isHardRefreshing = false
    /// Set by `consumePendingOptimisticPlaybackPosition()`, read (and
    /// cleared once caught up) by `mergeGuardingAgainstPlaybackRegression(_:)`
    /// — same shape and reasoning as `AssetDetailViewModel
    /// .optimisticPlaybackTarget`, adapted for a list of rails instead of a
    /// single displayed item.
    private var optimisticPlaybackTarget: (itemID: String, ticks: Int64, durationSeconds: TimeInterval)?
    /// See `AssetDetailViewModel.optimisticPositionTolerance`'s doc comment
    /// — same value, same reasoning (the guess and the value `PlayerViewModel
    /// .stop()` actually reports are read from the engine's clock a moment
    /// apart, so they can differ by a couple of real seconds even once the
    /// server has genuinely committed the right write).
    private static let optimisticPositionTolerance: Int64 = 5 * 10_000_000

    init(
        client: JellyfinAPIClient,
        userID: String,
        shuffle: @escaping ([DynamicRailCandidate]) -> [DynamicRailCandidate] = { $0.shuffled() },
        itemShuffle: @escaping @Sendable ([BaseItemDto]) -> [BaseItemDto] = { $0.shuffled() },
        reconnectRetrySchedule: [Double] = HomeViewModel.defaultReconnectRetrySchedule
    ) {
        self.client = client
        self.userID = userID
        self.itemShuffle = itemShuffle
        self.shuffle = shuffle
        self.reconnectRetrySchedule = reconnectRetrySchedule
    }

    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    /// Every `loadState` write goes through this rather than a bare
    /// assignment, so `LibraryAvailability.shared` — the signal `SearchView`'s
    /// landing page mirrors instead of duplicating Home's own retry/reconnect
    /// handling, see that type's doc comment — can never drift out of sync
    /// with it, including the flicker-suppressing mid-loop reset in
    /// `retryLoadIfNeeded()` below.
    private func setLoadState(_ newValue: LoadState) {
        loadState = newValue
        switch newValue {
        case .idle, .loading:
            LibraryAvailability.shared.update(.loading)
        case .loaded:
            LibraryAvailability.shared.update(.available)
        case .failed:
            LibraryAvailability.shared.update(.unavailable)
        }
    }

    /// A first load (or a retry from `.idle`/`.failed`) — flips `loadState`
    /// to `.loading` immediately, which is what drives `HomeView`'s
    /// full-screen placeholder. See `performFullLoad(resetLoadState:)` for
    /// the actual fetch; `hardRefresh()` shares the same body without that
    /// visible state transition.
    func load() async {
        await performFullLoad(resetLoadState: true)
    }

    /// The shared body behind both `load()` and `hardRefresh()`.
    /// `resetLoadState` is what tells them apart: `load()` needs
    /// `loadState` to visibly flip to `.loading`/`.loaded`/`.failed` (that's
    /// what drives `HomeView`'s full-screen placeholder for a first load or
    /// an error), while `hardRefresh()` must NOT touch `loadState` at
    /// all — it's already `.loaded`, and flipping it to `.loading` even
    /// momentarily would unmount `HomeView`'s `ScrollView` (via
    /// `placeholderState`) out from under a pull-to-refresh gesture the
    /// user is actively holding, killing the `.refreshable` spinner and
    /// `ScrollBottomObserver`'s KVO observation along with it.
    ///
    /// Populates the hero rail, libraries, and curated rails, then kicks
    /// off dynamic genre/studio rail discovery (`loadDynamicRailCandidates`)
    /// once they're showing — `loadState` (when `resetLoadState`) flips to
    /// `.loaded` as soon as the curated set is ready, deliberately not
    /// waiting on genre/studio discovery too, so Home doesn't feel slower
    /// because of it. A failure in that follow-on step doesn't affect
    /// `loadState`; Home stays usable without the extra rails rather than
    /// erroring out entirely over them.
    private func performFullLoad(resetLoadState: Bool) async {
        if resetLoadState { setLoadState(.loading) }
        refreshGeneration += 1
        consumePendingOptimisticPlaybackPosition()
        do {
            let images = await client.makeImageURLBuilder()

            let views = try await client.userViews(userID: userID)
            let moviesLibraryID = views.items.first { $0.collectionType == JellyfinCollectionType.movies }?.id
            let showsLibraryID = views.items.first { $0.collectionType == JellyfinCollectionType.tvShows }?.id
            self.moviesLibraryID = moviesLibraryID
            self.showsLibraryID = showsLibraryID

            async let heroCandidates = client.items(
                userID: userID,
                includeItemTypes: ["Movie", "Series"],
                sortBy: "Random",
                filters: ["IsUnplayed"],
                limit: 10
            )
            async let curated = fetchCuratedRails(
                images: images, moviesLibraryID: moviesLibraryID, showsLibraryID: showsLibraryID
            )

            heroItems = try await heroCandidates.items.map { MediaItem(dto: $0, images: images) }
            // AUDIO SUPPRESSION: `/Users/{id}/Views` has no server-side type
            // filter, so a Music library has to be dropped here instead —
            // see `MediaItem.isAudioLibrary`'s doc comment. Delete this
            // `.filter` once Dionysus Player supports browsing a Music
            // library.
            libraries = views.items
                .map { MediaItem(dto: $0, images: images) }
                .filter { !$0.isAudioLibrary }
            curatedRails = mergeGuardingAgainstPlaybackRegression(try await curated)
            if resetLoadState { setLoadState(.loaded) }

            // Reset dynamic-rail state before rediscovering — otherwise a
            // hard refresh's fresh discovery pass would have every
            // candidate silently filtered right back out by
            // `consumedDynamicRailCandidates` below, and dynamic rails
            // would never actually reshuffle the way "as if a fresh app
            // load" implies. A first `load()` starts with this state
            // already empty, so this is a no-op there.
            dynamicRails = []
            pendingDynamicRailCandidates = []
            consumedDynamicRailCandidates = []
            hasMoreDynamicRails = false
            dynamicRailCandidatesFailed = false
            await loadDynamicRailCandidates()
        } catch {
            if resetLoadState {
                setLoadState(.failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? String(localized: "Something went wrong loading your library.")
                ))
            }
            // else: a hard refresh's own failure — silently leave whatever
            // was already on screen rather than blanking an already-
            // populated page, matching `loadDynamicRailCandidates`'s and
            // `retryDynamicRailCandidatesIfNeeded`'s existing best-effort
            // philosophy.
        }
    }

    /// Builds Home's four curated rails (Continue Watching, Next Up,
    /// Recently Added Movies, Recently Added Shows, in that order — omitted
    /// when empty) — the shared fetch behind both `performFullLoad(resetLoadState:)`
    /// and `softRefresh()`.
    private func fetchCuratedRails(
        images: ImageURLBuilder, moviesLibraryID: String?, showsLibraryID: String?
    ) async throws -> [MediaCollectionRail] {
        // AUDIO SUPPRESSION: excludeItemTypes keeps audio/music out of
        // Continue Watching server-side — see `JellyfinAPIClient
        // .audioItemTypeExclusions`'s doc comment. Delete this argument
        // once Dionysus Player supports audio/music playback.
        async let resume = client.resumeItems(userID: userID, excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions)
        async let upNext = client.nextUp(userID: userID, limit: 16)
        async let latestMovies = client.latestItems(userID: userID, parentID: moviesLibraryID, limit: 16)
        async let latestShows = client.latestItems(userID: userID, parentID: showsLibraryID, limit: 16)

        var newRails: [MediaCollectionRail] = []
        func appendRail(_ title: String, _ dtos: [BaseItemDto], seeAllQuery: CollectionQuery? = nil) {
            guard !dtos.isEmpty else { return }
            let items = dtos.map { MediaItem(dto: $0, images: images) }
            newRails.append(MediaCollectionRail(title: title, items: items, seeAllQuery: seeAllQuery))
        }

        let resumeItems = try await resume.items
        appendRail(String(localized: "Continue Watching"), resumeItems)
        // Jellyfin's `/Shows/NextUp` isn't guaranteed disjoint from
        // `/Users/{id}/Items/Resume` — a show can surface the same
        // episode from both endpoints (e.g. right after resuming
        // playback, before the server's own "next up" state has caught
        // up) — so an item already shown in Continue Watching is
        // filtered out here rather than shown a second time.
        let resumeItemIDs = Set(resumeItems.map(\.id))
        let nextUpItems = try await upNext.items.filter { !resumeItemIDs.contains($0.id) }
        appendRail(String(localized: "Next Up"), nextUpItems)
        appendRail(
            String(localized: "Recently Added Movies"), try await latestMovies,
            // Preset newest-first — matches what "Recently Added"
            // already means for this rail, rather than landing on the
            // grid's own bare default (Title, ascending) and making the
            // user reapply the exact ordering that got them here.
            seeAllQuery: CollectionQuery(
                title: String(localized: "Movies"), parentID: moviesLibraryID, includeItemTypes: ["Movie"],
                initialSortField: .dateAdded, initialSortOrder: .descending
            )
        )
        appendRail(
            String(localized: "Recently Added Shows"), try await latestShows,
            seeAllQuery: CollectionQuery(
                title: String(localized: "Shows"), parentID: showsLibraryID, includeItemTypes: ["Series"],
                initialSortField: .dateAdded, initialSortOrder: .descending
            )
        )
        return newRails
    }

    /// Consumes `RecentPlaybackBroadcaster.shared`'s pending outcome (if
    /// any) exactly once: records it as `optimisticPlaybackTarget` (used by
    /// `mergeGuardingAgainstPlaybackRegression(_:)` below to keep a
    /// subsequent fetch from regressing it), and — if the item is already
    /// showing in `curatedRails` right now — overlays it there immediately
    /// too, so the UI never even flashes stale data while the fetch that
    /// follows is in flight. Called at the top of both `performSoftRefresh()`
    /// and `performFullLoad(resetLoadState:)`, so a resume point looks
    /// correct on Home the moment it becomes visible again after playback —
    /// the same thing `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)`
    /// already does for the detail page itself. See `RecentPlaybackBroadcaster`'s
    /// own doc comment for why Home needed this at all (confirmed live,
    /// 2026-09-02: a resume point looked accurate on the detail page right
    /// after playback but stale on Home moments later — Home's soft refresh
    /// was a single unguarded server fetch with no optimistic overlay).
    private func consumePendingOptimisticPlaybackPosition() {
        guard let outcome = RecentPlaybackBroadcaster.shared.consume(), outcome.durationSeconds > 0 else { return }
        optimisticPlaybackTarget = (
            itemID: outcome.itemID,
            ticks: Int64(outcome.positionSeconds * 10_000_000),
            durationSeconds: outcome.durationSeconds
        )
        curatedRails = curatedRails.map { rail in
            var rail = rail
            rail.items = rail.items.map { item in
                item.id == outcome.itemID
                    ? item.withOptimisticPlaybackPosition(seconds: outcome.positionSeconds, duration: outcome.durationSeconds)
                    : item
            }
            return rail
        }
    }

    /// Keeps a freshly-fetched set of curated rails from regressing
    /// `optimisticPlaybackTarget` back to stale data — same reasoning as
    /// `AssetDetailViewModel.refreshItem()`'s own `optimisticTarget`/
    /// `caughtUp` check (see that method's doc comment for why an early
    /// fetch almost always still carries the server's old, not-yet-committed
    /// position rather than genuinely differing data). Whichever rail item
    /// matches `optimisticPlaybackTarget.itemID` is left showing the
    /// optimistic value until a fetch's own position catches up to it
    /// (within `optimisticPositionTolerance`) or the server reports it fully
    /// played — either clears the target so future fetches are trusted
    /// again.
    private func mergeGuardingAgainstPlaybackRegression(_ freshRails: [MediaCollectionRail]) -> [MediaCollectionRail] {
        guard let target = optimisticPlaybackTarget else { return freshRails }
        var stillPending = false
        let merged = freshRails.map { rail -> MediaCollectionRail in
            var rail = rail
            rail.items = rail.items.map { item -> MediaItem in
                guard item.id == target.itemID else { return item }
                let fetchedTicks = item.dto.userData?.playbackPositionTicks ?? 0
                let played = item.dto.userData?.played ?? false
                let caughtUp = fetchedTicks >= target.ticks - Self.optimisticPositionTolerance || played
                if caughtUp {
                    // Trust the fetch's own `playbackPositionTicks`, but not
                    // its raw `playedPercentage` in isolation — confirmed
                    // live (2026-09-02): Jellyfin can commit those two
                    // fields at different times, so a fetch whose *ticks*
                    // have already caught up to a scrub can still carry a
                    // stale `playedPercentage` left over from before it (a
                    // backward scrub in particular — ticks moved back, but
                    // the percentage field hadn't been recalculated yet).
                    // `MediaItem.playedFraction` prefers the raw percentage
                    // over computing it from ticks, so left alone this
                    // regressed the rail's progress bar right back to the
                    // stale value even though the position itself was
                    // already correct. Recompute it from this fetch's own
                    // ticks instead of trusting the separate field — skipped
                    // when `played`, since a fully-watched item's position
                    // is reset by the server and `hasResumeProgress` already
                    // gates its progress bar on `!isPlayed` first, so
                    // there's nothing here worth overriding.
                    guard !played, let runTimeTicks = item.dto.runTimeTicks, runTimeTicks > 0 else { return item }
                    return item.withOptimisticPlaybackPosition(
                        seconds: Double(fetchedTicks) / 10_000_000, duration: Double(runTimeTicks) / 10_000_000
                    )
                }
                stillPending = true
                return item.withOptimisticPlaybackPosition(
                    seconds: TimeInterval(target.ticks) / 10_000_000, duration: target.durationSeconds
                )
            }
            return rail
        }
        if !stillPending { optimisticPlaybackTarget = nil }
        return merged
    }

    /// Discovers every eligible dynamic rail — genres and studios for both
    /// movies and shows, plus actors and directors (unscoped by content
    /// type, see `DynamicRailCandidate`'s doc comment) — six concurrent
    /// discovery calls in total, shuffles the combined candidate list
    /// together (actors/directors mixed in with genres/studios, not a
    /// separate pool), and loads the first batch immediately. Each
    /// discovery call is independently best-effort (`try?`) — e.g. a failed
    /// director lookup shouldn't also wipe out genre rails that succeeded.
    /// Can be called more than once per `HomeViewModel` lifetime (a
    /// connectivity-triggered retry, or a `hardRefresh()`, re-runs it
    /// wholesale — see `retryDynamicRailCandidatesIfNeeded()`), so
    /// candidates already represented by a rail (`consumedDynamicRailCandidates`)
    /// are filtered out before the fresh discovery results get queued, or a
    /// retry would re-append rails that are already showing.
    ///
    /// A brief detour (2026-08-23): tried tiering candidates by category
    /// (genres, then studios, then actors/directors, instead of one flat
    /// shuffle) after a user report of "often 0 or 1 dynamic rail" and
    /// qualifying-rate numbers measured against this codebase's own small
    /// LAN test server suggested studios/actors/directors rarely clear
    /// `minimumDynamicRailItemCount`. Reverted the same day, user-confirmed
    /// worse: on their real library, plenty of studio/actor/director
    /// candidates *do* qualify, so gating them behind exhausting every
    /// genre candidate first (up to ~40) just delayed real content that
    /// used to show up quickly. The measured rates were an artifact of
    /// testing against a small, unrepresentative library, not a real
    /// property of "studios/actors/directors are rarely good candidates" —
    /// don't reintroduce category tiering off that reasoning without fresh
    /// numbers from the *reporting user's* own library.
    private func loadDynamicRailCandidates() async {
        async let movieGenres = client.genres(userID: userID, includeItemTypes: ["Movie"])
        async let showGenres = client.genres(userID: userID, includeItemTypes: ["Series"])
        async let movieStudios = client.studios(userID: userID, includeItemTypes: ["Movie"])
        async let showStudios = client.studios(userID: userID, includeItemTypes: ["Series"])
        async let actors = client.persons(userID: userID, personTypes: ["Actor"], limit: Self.personDiscoveryLimit)
        async let directors = client.persons(
            userID: userID, personTypes: ["Director"], limit: Self.personDiscoveryLimit
        )

        var candidates: [DynamicRailCandidate] = []
        var anyFetchFailed = false
        do {
            candidates += try await movieGenres.items.map { DynamicRailCandidate.genre(kind: .movie, name: $0.name) }
        } catch { anyFetchFailed = true }
        do {
            candidates += try await showGenres.items.map { DynamicRailCandidate.genre(kind: .series, name: $0.name) }
        } catch { anyFetchFailed = true }
        do {
            candidates += try await movieStudios.items.map { DynamicRailCandidate.studio(kind: .movie, name: $0.name) }
        } catch { anyFetchFailed = true }
        do {
            candidates += try await showStudios.items.map { DynamicRailCandidate.studio(kind: .series, name: $0.name) }
        } catch { anyFetchFailed = true }
        do {
            candidates += try await actors.items.map { DynamicRailCandidate.actor(name: $0.name) }
        } catch { anyFetchFailed = true }
        do {
            candidates += try await directors.items.map { DynamicRailCandidate.director(name: $0.name) }
        } catch { anyFetchFailed = true }

        candidates.removeAll { consumedDynamicRailCandidates.contains($0) }
        pendingDynamicRailCandidates = shuffle(candidates)
        hasMoreDynamicRails = !pendingDynamicRailCandidates.isEmpty
        dynamicRailCandidatesFailed = anyFetchFailed
        await loadMoreDynamicRails()
    }

    /// Called by `HomeView` when `ConnectivityMonitor` transitions back
    /// online — retries `load()` itself if it never succeeded (a cold
    /// launch that hit this while genuinely offline, or a previous
    /// in-session failure), no-opping once it already has. `isOffline`
    /// flipping `false` only means *some* request succeeded (see
    /// `ConnectivityMonitor`'s own doc comment) — often a lightweight
    /// scenePhase-driven health check that can beat the network actually
    /// stabilizing enough for a real, heavier `/Users/{id}/Views` fan-out
    /// to succeed (confirmed live: Wi-Fi reassociating can report
    /// "connected" a couple of seconds before DNS/routing to a LAN server
    /// is actually usable). A single immediate retry right at that instant
    /// can still land in that same window and fail again — instead this
    /// retries with backoff (`reconnectRetrySchedule`), so a genuinely
    /// still-unreachable server still ends up back at `.failed` rather than
    /// retrying forever, but a server that's a few seconds from being ready
    /// gets caught by a later attempt instead of leaving the user stuck on
    /// a stale failure with no obvious path forward besides tapping "Try
    /// Again" themselves.
    ///
    /// Deliberately resets a mid-loop failure back to `.loading` (rather
    /// than leaving `load()`'s own `.failed` write in place) before every
    /// attempt but the last — both writes happen synchronously with no
    /// `await` in between, so SwiftUI never actually renders the
    /// intermediate `.failed` state, avoiding a flash of "Something went
    /// wrong" between retries. Once the schedule is exhausted, the final
    /// attempt's outcome (loaded or failed) is left as-is, so a genuinely
    /// still-unreachable server ends up on the same `.failed` + visible
    /// "Try Again" a single attempt would have shown.
    ///
    /// Every retry entry point — `HomeView`'s own "Try Again" buttons,
    /// `LibraryAvailability.retryAction` (`SearchView`'s mirrored "Try
    /// Again"), and `HomeView`'s automatic reconnect hook — calls this same
    /// method rather than `load()` directly, and concurrent callers
    /// coalesce into one shared attempt via `inFlightRetry` (same idea as
    /// `JellyfinAPIClient.inFlightReauth`) instead of racing independent
    /// `load()` calls. A real bug found live (2026-08-29): a manual retry
    /// tapped while the automatic backoff loop was still mid-cycle could
    /// have the loop's own next scheduled attempt fire *after* the manual
    /// tap's `load()` had already succeeded, silently clobbering that
    /// success back down to `.loading`/`.failed` with no further attempt
    /// left to recover it — the visible symptom was a "Try Again" tap that
    /// just spun forever with no outcome.
    func retryLoadIfNeeded() async {
        if let inFlightRetry {
            await inFlightRetry.value
            return
        }
        guard loadState != .loaded else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRetryLoop()
        }
        inFlightRetry = task
        await task.value
        inFlightRetry = nil
    }

    private func runRetryLoop() async {
        let delays = [0.0] + reconnectRetrySchedule
        for (index, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await load()
            if loadState == .loaded { return }
            if index < delays.count - 1 { setLoadState(.loading) }
        }
    }

    /// Silently re-fetches just the four curated rails (Continue Watching,
    /// Next Up, Recently Added Movies, Recently Added Shows) in place —
    /// called by `HomeView` whenever the user returns to Home from
    /// elsewhere (a tab switch, or in-page back navigation back to Home's
    /// root), to pick up resume points / newly-watched status / a changed
    /// "next up" episode / newly added items without disturbing the hero
    /// banner, library rail, dynamic rails, or scroll position the way a
    /// `hardRefresh()` would. Never user-triggered directly — `hardRefresh()`
    /// is what pull-to-refresh and the VoiceOver refresh button call.
    ///
    /// Deliberately has no visible loading UI at all: `loadState` never
    /// changes, and the current curated rails stay on screen until the
    /// fresh ones replace them in one shot (or stay as-is on failure — this
    /// is a best-effort background refresh, not a user-initiated action
    /// that owes anyone an error state).
    ///
    /// No-ops if Home hasn't finished its first `load()` yet — that case is
    /// already owned by `load()`/`retryLoadIfNeeded()`. Concurrent callers
    /// coalesce via `inFlightSoftRefresh`, same idea as `inFlightRetry`.
    func softRefresh() async {
        if let inFlightSoftRefresh {
            await inFlightSoftRefresh.value
            return
        }
        guard loadState == .loaded else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSoftRefresh()
        }
        inFlightSoftRefresh = task
        await task.value
        inFlightSoftRefresh = nil
    }

    private func performSoftRefresh() async {
        // Cheap early-out, not required for correctness (the generation
        // check below already covers this) — avoids firing a redundant
        // network fetch when a hardRefresh() is already underway.
        guard !isHardRefreshing else { return }
        let generation = refreshGeneration
        consumePendingOptimisticPlaybackPosition()
        let images = await client.makeImageURLBuilder()
        guard let result = try? await fetchCuratedRails(
            images: images, moviesLibraryID: moviesLibraryID, showsLibraryID: showsLibraryID
        ) else { return }
        // A hardRefresh() may have started (or even finished) while this
        // was in flight — e.g. switching into the Home tab fires a soft
        // refresh, and an immediate double-tap of the VoiceOver refresh
        // button fires a hard one, a normal VoiceOver interaction pattern.
        // `refreshGeneration` only ever advances, so if it moved since this
        // started, a hard refresh's fresher (and more complete) data has
        // already landed — defer to it rather than clobbering it with this
        // slower, narrower result.
        guard generation == refreshGeneration else { return }
        // Getting the *data* right here was only ever half the job — see
        // `MediaItem.==` for the other half, and for a cautionary tale
        // about this exact line. A correct merge assigned here could still
        // fail to reach the screen, because `MediaItem`'s `Equatable` used
        // to compare ids only and so reported a freshly-updated resume
        // position as "unchanged" to SwiftUI's diffing. That was chased for
        // a while as a timing problem in this file (a `Task.yield()` here
        // fixed it ~1/3 of live trials; a stronger `DispatchQueue.main.async`
        // wait made it worse, 0/5) and then papered over with logging calls
        // whose only real effect was perturbing what SwiftUI compared. It
        // was never a scheduling problem, and nothing about the fix belongs
        // in this method.
        curatedRails = mergeGuardingAgainstPlaybackRegression(result)
    }

    /// Re-fetches everything on Home — hero banner, libraries, curated
    /// rails, and a freshly reshuffled set of dynamic rails — as if this
    /// were a fresh app load, without blanking the page while it's in
    /// flight (unlike `load()`/`retryLoadIfNeeded()`, `loadState` stays
    /// `.loaded` throughout — see `performFullLoad(resetLoadState:)`'s doc
    /// comment). Called by `HomeView`'s `.refreshable` pull-to-refresh
    /// gesture and by its VoiceOver-only refresh button, both via this same
    /// coalesced entry point rather than `load()` directly.
    ///
    /// No-ops if Home hasn't finished its first `load()` yet (nothing to
    /// refresh over). A failure leaves whatever was already on screen in
    /// place rather than erroring the whole page out from under the user —
    /// see `performFullLoad(resetLoadState:)`'s catch branch. Concurrent
    /// callers coalesce via `inFlightHardRefresh`, same idea as
    /// `inFlightRetry`.
    func hardRefresh() async {
        if let inFlightHardRefresh {
            await inFlightHardRefresh.value
            return
        }
        guard loadState == .loaded else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.isHardRefreshing = true
            await self.performFullLoad(resetLoadState: false)
            self.isHardRefreshing = false
        }
        inFlightHardRefresh = task
        await task.value
        inFlightHardRefresh = nil
    }

    /// Called by `HomeView` when `ConnectivityMonitor` transitions back
    /// online — re-runs dynamic rail discovery only if the last attempt
    /// actually failed (typically because it landed in the brief window
    /// right after reconnecting), so a library that legitimately has no
    /// dynamic rails to offer, or an attempt that already succeeded,
    /// doesn't get needlessly re-fetched. The re-run itself still repeats
    /// all six discovery calls (no cheaper way to know just from this
    /// which ones failed last time), but `loadDynamicRailCandidates()`'s own
    /// `consumedDynamicRailCandidates` filtering keeps that safe — whichever
    /// candidates already became rails before the failure won't be
    /// requeued or appended a second time.
    func retryDynamicRailCandidatesIfNeeded() async {
        guard dynamicRailCandidatesFailed else { return }
        dynamicRailCandidatesFailed = false
        await loadDynamicRailCandidates()
    }

    /// Fetches the next `dynamicRailBatchSize` candidates (concurrently)
    /// and appends whichever clear `minimumDynamicRailItemCount` as new
    /// rails — called once by `loadDynamicRailCandidates` for the first
    /// batch, and by `HomeView`'s scroll-triggered sentinel for every batch
    /// after. A candidate whose fetch fails or comes back too sparse is
    /// silently dropped rather than shown as a barely-populated rail.
    func loadMoreDynamicRails() async {
        guard !isLoadingMoreDynamicRails, !pendingDynamicRailCandidates.isEmpty else { return }
        isLoadingMoreDynamicRails = true
        defer { isLoadingMoreDynamicRails = false }

        let batch = Array(pendingDynamicRailCandidates.prefix(Self.dynamicRailBatchSize))
        pendingDynamicRailCandidates.removeFirst(batch.count)
        hasMoreDynamicRails = !pendingDynamicRailCandidates.isEmpty

        let images = await client.makeImageURLBuilder()
        // Captured as a local, not read as `Self.minimumDynamicRailItemCount`
        // inside the task group below — `HomeViewModel` is `@MainActor`, so
        // its static members are actor-isolated too, and the group's child
        // tasks run outside that isolation (same reason `client`/`userID`
        // are captured explicitly rather than read via `self`).
        let minimumItemCount = Self.minimumDynamicRailItemCount
        // Same reasoning as `minimumItemCount` above — read once here, on
        // the actor, then captured by value into each child task below.
        let moviesLibraryID = self.moviesLibraryID
        let showsLibraryID = self.showsLibraryID
        let itemShuffle = self.itemShuffle
        // Tagged with its index in `batch` so results can be restored to
        // the batch's (already-shuffled) order afterward — task-group
        // completion order isn't otherwise guaranteed to match it. Also
        // carries the candidate itself back out (not just its rail), so the
        // ones that actually produced a rail can be recorded into
        // `consumedDynamicRailCandidates` below.
        let fetched = await withTaskGroup(of: (Int, DynamicRailCandidate, MediaCollectionRail?).self) { group in
            for (index, candidate) in batch.enumerated() {
                group.addTask { [client, userID, itemShuffle] in
                    // Try a genuine server-side random sample across the
                    // candidate's *entire* matching set first — `limit: 16`
                    // alone, with no `sortBy`, would otherwise default to
                    // `SortBy=SortName` and cap every rail to the
                    // alphabetically-first 16 items matching it forever (a
                    // large genre like "Action" would only ever show
                    // A-through-D titles, since the client-side shuffle
                    // below can only reorder whichever 16 the server handed
                    // back, not reach further into the catalog). A prior
                    // attempt at this same `SortBy=Random` call was
                    // abandoned after a user report of it reproducing as
                    // *zero* dynamic rails on a real server/library — but
                    // that report predates a separate, unrelated fix (the
                    // `ScrollBottomObserver` attach-race in
                    // `home-scrollbottomobserver-attach-race`) that was
                    // found landing in the exact same investigation pass,
                    // so it's plausible (though not provable in hindsight)
                    // the two got conflated. Rather than re-trusting or
                    // re-dismissing that report outright, fall back to
                    // exactly the old safe behavior — default alphabetical
                    // sort, same 16-item cap — whenever the random-sorted
                    // attempt fails outright or comes back thin (fewer than
                    // `minimumItemCount`, indistinguishable from "this
                    // candidate genuinely doesn't have that many items"
                    // without more signal, so retrying is the safe move).
                    // See `home-dynamic-rails-random-sort-bug` memory.
                    func fetchCandidateItems(sortBy: String) async -> [BaseItemDto]? {
                        switch candidate {
                        case .genre(let kind, let name):
                            return try? await client.items(
                                userID: userID, includeItemTypes: [kind.rawValue],
                                sortBy: sortBy, genres: [name], limit: 16
                            ).items
                        case .studio(let kind, let name):
                            return try? await client.items(
                                userID: userID, includeItemTypes: [kind.rawValue],
                                sortBy: sortBy, studios: [name], limit: 16
                            ).items
                        case .actor(let name):
                            return try? await client.items(
                                userID: userID, includeItemTypes: ["Movie", "Series"], sortBy: sortBy,
                                person: name, personTypes: ["Actor"], limit: 16
                            ).items
                        case .director(let name):
                            return try? await client.items(
                                userID: userID, includeItemTypes: ["Movie", "Series"], sortBy: sortBy,
                                person: name, personTypes: ["Director"], limit: 16
                            ).items
                        }
                    }

                    var dtos = await fetchCandidateItems(sortBy: "Random")
                    if dtos == nil || dtos!.count < minimumItemCount {
                        dtos = await fetchCandidateItems(sortBy: "SortName")
                    }
                    guard let dtos, dtos.count >= minimumItemCount else { return (index, candidate, nil) }
                    // Still shuffled client-side even though the random
                    // fetch above should already be server-randomized —
                    // cheap, harmless, and a hedge against the server's own
                    // "random" turning out weak (e.g. session-cached) on
                    // some Jellyfin versions; it's also what actually
                    // reorders the fallback-path result when the random
                    // fetch didn't pan out.
                    let items = itemShuffle(dtos).map { MediaItem(dto: $0, images: images) }
                    let rail = MediaCollectionRail(
                        title: candidate.railTitle, items: items,
                        seeAllQuery: candidate.seeAllQuery(moviesLibraryID: moviesLibraryID, showsLibraryID: showsLibraryID)
                    )
                    return (index, candidate, rail)
                }
            }
            var results: [(Int, DynamicRailCandidate, MediaCollectionRail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        // Collected into a local array and appended once, rather than
        // calling `dynamicRails.append(rail)` inside the loop —
        // `dynamicRails` is an `@Observable` property that `HomeView` reads
        // (via `rails`) to build its `LazyVStack` of rails, so each
        // separate append used to fire its own SwiftUI transaction/layout
        // flush over the whole rail list. Landing up to `dynamicRailBatchSize`
        // (5) of those back-to-back, right as `HomeView`'s scroll-triggered
        // sentinel fires (i.e. while the user is actively scrolling), was a
        // plausible contributor to an intermittently-reported real-device
        // freeze in this exact region — see
        // `home-collection-nav-freeze-unconfirmed` memory, occurrence 3.
        // One append means one flush instead of up to five.
        let newRails = fetched.compactMap { _, candidate, rail in
            rail.map { (candidate, $0) }
        }
        dynamicRails.append(contentsOf: newRails.map(\.1))
        for (candidate, _) in newRails {
            consumedDynamicRailCandidates.insert(candidate)
        }
    }
}
