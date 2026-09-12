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
    /// The user's libraries, for the rail at the top of Home.
    private(set) var libraries: [MediaItem] = []
    /// Continue Watching, Next Up, Recently Added Movies and Shows, in that
    /// order, omitted when empty. Separate from `dynamicRails` so
    /// `softRefresh()` can replace them in place without touching the dynamic
    /// rails or their pagination state.
    private(set) var curatedRails: [MediaCollectionRail] = []
    /// However many dynamic rails — genre, studio, actor, director — have loaded
    /// so far.
    private(set) var dynamicRails: [MediaCollectionRail] = []
    /// `HomeView` renders this as one list; the split above matters only to
    /// `softRefresh()`/`hardRefresh()`.
    var rails: [MediaCollectionRail] { curatedRails + dynamicRails }
    private(set) var loadState: LoadState = .idle

    /// Candidates discovered but not yet fetched into rails, drawn from the front
    /// in batches by `loadMoreDynamicRails`, so Home fetches only as many as the
    /// user scrolls to.
    private var pendingDynamicRailCandidates: [DynamicRailCandidate] = []
    /// Whether candidates remain. `HomeView` shows its load-more sentinel exactly
    /// while true, so it disappears rather than triggering empty loads.
    private(set) var hasMoreDynamicRails = false
    /// Drives the loading indicator at the bottom of the rail list, and guards
    /// `loadMoreDynamicRails` against a second batch if a fast scroll re-triggers
    /// the sentinel before the first finishes.
    private(set) var isLoadingMoreDynamicRails = false
    /// Set when the last `loadDynamicRailCandidates()` had a fetch throw,
    /// typically a connectivity blip after reconnecting — distinct from the
    /// candidate list legitimately being empty. `HomeView` reads it to decide
    /// whether a later back-online transition is worth retrying.
    private(set) var dynamicRailCandidatesFailed = false
    /// Candidates already turned into visible rails, so a retry after a partial
    /// failure can't requeue one that is showing. Candidates that failed
    /// `minimumDynamicRailItemCount` are not tracked: retrying those is harmless,
    /// failing the bar again or correctly succeeding if the library changed.
    private var consumedDynamicRailCandidates: Set<DynamicRailCandidate> = []

    /// Kept small: each batch fires this many concurrent rail fetches and appends
    /// them in one state update, landing as the scroll sentinel fires — while the
    /// user is scrolling through exactly that region. A batch of 10 put ten rail
    /// sections' network fetches and first-page image loads on the main thread at
    /// once, a plausible contributor to a reported device freeze scrolling into
    /// the dynamic rails.
    /// Resolved once by `load()`/`hardRefresh()` and reused by the curated rails'
    /// `seeAllQuery`s and by `loadMoreDynamicRails`. Stored rather than a local,
    /// since the scroll sentinel calls that method long after `performFullLoad()`
    /// has returned.
    private var moviesLibraryID: String?
    private var showsLibraryID: String?

    private static let dynamicRailBatchSize = 5
    /// How many items a candidate needs to become a rail. `/Items` has no
    /// minimum-result-count param, so this is a post-fetch check — and a reliable
    /// one, since `loadMoreDynamicRails` already fetches up to 16 per candidate
    /// and the returned count measures real availability within that cap.
    private static let minimumDynamicRailItemCount = 5
    /// Caps the `/Persons` discovery calls. Genres and studios number a few dozen,
    /// but a library's cast and crew can run to thousands of full `BaseItemDto`s,
    /// fetched on every Home load just to seed candidates. The list is shuffled
    /// anyway, so which 200 doesn't matter.
    private static let personDiscoveryLimit = 200
    /// Delays before each reconnect retry of `load()`, when an offline-to-online
    /// transition still finds `loadState` unloaded. The first attempt is
    /// immediate; these precede each subsequent one. Bounded, so a still
    /// unreachable server leaves `loadState` at `.failed` and its "Try Again"
    /// button working rather than retrying forever.
    ///
    /// Just one retry, unlike `reauthBackoffSchedule`: a 401 means the server
    /// already responded, so each of those retries is a fast round trip, while a
    /// reconnect retry can hit a server that is routable but not answering and
    /// costs the full 20s request timeout. Four retries measured as up to ~100s
    /// of unmoving spinner before settling back to the offline screen. One bounds
    /// the worst case near 2×20s while still catching the motivating case — Wi-Fi
    /// reassociating seconds before the server is reachable.
    static let defaultReconnectRetrySchedule: [Double] = [2.0]

    private let client: JellyfinAPIClient
    private let userID: String
    /// Injected so tests can pin the order with an identity closure. Every
    /// `load()` reshuffles, so the dynamic rails' order differs each time.
    private let shuffle: ([DynamicRailCandidate]) -> [DynamicRailCandidate]
    /// As `shuffle`, but for a rail's items rather than which rails appear.
    /// `@Sendable` because `loadMoreDynamicRails`' child tasks call it.
    private let itemShuffle: @Sendable ([BaseItemDto]) -> [BaseItemDto]
    /// Injectable so tests can exercise `retryLoadIfNeeded()` without waiting out
    /// the real delays.
    private let reconnectRetrySchedule: [Double]
    /// Coalesces concurrent `retryLoadIfNeeded()` callers into one attempt.
    private var inFlightRetry: Task<Void, Never>?
    /// Bumped at the top of every `performFullLoad(resetLoadState:)`, so
    /// `softRefresh()` can detect a concurrent `hardRefresh()` and defer to it.
    private var refreshGeneration = 0
    /// Coalesces concurrent `softRefresh()` callers.
    private var inFlightSoftRefresh: Task<Void, Never>?
    /// Coalesces concurrent `hardRefresh()` callers.
    private var inFlightHardRefresh: Task<Void, Never>?
    /// Drives the VoiceOver-only refresh button's spinner: `hardRefresh()`'s only
    /// visible signal, `loadState` not changing during one.
    private(set) var isHardRefreshing = false
    /// Set by `consumePendingOptimisticPlaybackPosition()`, read and cleared by
    /// `mergeGuardingAgainstPlaybackRegression(_:)`.
    /// `AssetDetailViewModel.optimisticPlaybackTarget`'s shape, for a list of
    /// rails rather than one displayed item.
    private var optimisticPlaybackTarget: (itemID: String, ticks: Int64, durationSeconds: TimeInterval)?
    /// `AssetDetailViewModel.optimisticPositionTolerance`'s value and reasoning.
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

    /// Every `loadState` write goes through this rather than a bare assignment,
    /// so `LibraryAvailability.shared` — which `SearchView`'s landing page
    /// mirrors — can't drift out of sync, including through the
    /// flicker-suppressing reset in `retryLoadIfNeeded()`.
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

    /// A first load, or a retry from `.idle`/`.failed`: flips `loadState` to
    /// `.loading`, driving `HomeView`'s full-screen placeholder.
    /// `hardRefresh()` shares `performFullLoad`'s body without that transition.
    func load() async {
        await performFullLoad(resetLoadState: true)
    }

    /// The shared body behind `load()` and `hardRefresh()`. `resetLoadState`
    /// tells them apart: `load()` needs the visible flip that drives `HomeView`'s
    /// placeholder, while `hardRefresh()` must not touch `loadState` at all —
    /// already `.loaded`, and flipping it would unmount `HomeView`'s `ScrollView`
    /// under a pull-to-refresh the user is holding, killing the `.refreshable`
    /// spinner and `ScrollBottomObserver`'s KVO along with it.
    ///
    /// Populates the hero rail, libraries and curated rails, then starts dynamic
    /// rail discovery. `loadState` flips to `.loaded` as soon as the curated set
    /// is ready rather than waiting on discovery, and a failure there leaves Home
    /// usable without the extra rails rather than erroring out.
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
            // filter, so a Music library is dropped here. Delete once browsing
            // one is supported.
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

    /// Consumes `RecentPlaybackBroadcaster.shared`'s pending outcome exactly
    /// once: records it as `optimisticPlaybackTarget` (which
    /// `mergeGuardingAgainstPlaybackRegression(_:)` uses to keep a later
    /// fetch from regressing it), and overlays it onto `curatedRails`
    /// immediately if the item is already showing, so Home doesn't flash a
    /// stale resume point while the following fetch is in flight. Called at
    /// the top of `performSoftRefresh()` and `performFullLoad(resetLoadState:)`.
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

    /// Keeps freshly-fetched rails from regressing `optimisticPlaybackTarget`
    /// back to a position the server hasn't committed yet — same check as
    /// `AssetDetailViewModel.refreshItem()`. The matching rail item keeps the
    /// optimistic value until a fetch catches up to it (within
    /// `optimisticPositionTolerance`) or reports it fully played; either
    /// clears the target.
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
                    // Jellyfin commits `playbackPositionTicks` and
                    // `playedPercentage` at different times, so a fetch whose
                    // ticks have caught up can still carry a stale percentage
                    // (notably after a backward scrub). `MediaItem.playedFraction`
                    // prefers the raw percentage, which would regress the
                    // progress bar, so recompute it from this fetch's ticks.
                    // Skipped when `played`: the server resets position then,
                    // and `hasResumeProgress` already gates on `!isPlayed`.
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

    /// Discovers every eligible dynamic rail — genres and studios for movies
    /// and shows, plus actors and directors — in six concurrent calls,
    /// shuffles them into one combined candidate list, and loads the first
    /// batch. Each call is independently best-effort, so a failed director
    /// lookup doesn't wipe out genre rails that succeeded.
    ///
    /// Can run more than once per lifetime (`retryDynamicRailCandidatesIfNeeded()`,
    /// `hardRefresh()`), so candidates already made into rails
    /// (`consumedDynamicRailCandidates`) are filtered out first, or a retry
    /// would re-append rails already showing.
    ///
    /// Don't tier candidates by category (genres first, then studios, then
    /// people): tried and reverted as user-confirmed worse. Qualifying rates
    /// suggesting studios/actors/directors rarely clear
    /// `minimumDynamicRailItemCount` were an artifact of a small test
    /// library; on a real one they qualify often, and tiering just delayed
    /// them behind up to ~40 genre candidates.
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

    /// Retries `load()` if it never succeeded, no-opping once it has. Called
    /// by `HomeView` on a `ConnectivityMonitor` transition back online, and
    /// by every manual retry entry point — `HomeView`'s "Try Again" buttons
    /// and `LibraryAvailability.retryAction` (`SearchView`'s mirrored one).
    ///
    /// Retries with backoff (`reconnectRetrySchedule`) rather than once,
    /// because `isOffline` going `false` only means *some* request succeeded
    /// (see `ConnectivityMonitor`) — often a lightweight health check that
    /// beats the network stabilizing enough for the heavier
    /// `/Users/{id}/Views` fan-out. A reassociating Wi-Fi link can report
    /// connected seconds before DNS/routing to a LAN server is usable, and a
    /// single immediate retry lands in that same window.
    ///
    /// Resets a mid-loop failure back to `.loading` before every attempt but
    /// the last. Both writes happen with no `await` between them, so SwiftUI
    /// never renders the intermediate `.failed`, avoiding a flash of
    /// "Something went wrong" between retries. The last attempt's outcome is
    /// left as-is, so a still-unreachable server ends on `.failed` with a
    /// working "Try Again".
    ///
    /// Concurrent callers coalesce via `inFlightRetry` (same idea as
    /// `JellyfinAPIClient.inFlightReauth`). Without it, a manual retry tapped
    /// mid-backoff could have the loop's next attempt fire after the manual
    /// `load()` had already succeeded, clobbering it back to
    /// `.loading`/`.failed` with no attempt left to recover — a "Try Again"
    /// that spun forever.
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

    /// Silently re-fetches just the four curated rails in place, picking up
    /// resume points, watched status, a changed "next up" episode and newly
    /// added items without disturbing the hero banner, library rail, dynamic
    /// rails or scroll position the way `hardRefresh()` would. Called by
    /// `HomeView` when the user returns to Home from elsewhere; never
    /// user-triggered directly.
    ///
    /// Has no loading UI: `loadState` never changes, and the current rails
    /// stay until fresh ones replace them in one shot, or stay as-is on
    /// failure — a best-effort background refresh owes no error state.
    ///
    /// No-ops before the first `load()` succeeds; that case belongs to
    /// `load()`/`retryLoadIfNeeded()`. Concurrent callers coalesce via
    /// `inFlightSoftRefresh`, same idea as `inFlightRetry`.
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
        // Early-out, not required for correctness (the generation check below
        // covers it) — avoids a redundant fetch during a hardRefresh().
        guard !isHardRefreshing else { return }
        let generation = refreshGeneration
        consumePendingOptimisticPlaybackPosition()
        let images = await client.makeImageURLBuilder()
        guard let result = try? await fetchCuratedRails(
            images: images, moviesLibraryID: moviesLibraryID, showsLibraryID: showsLibraryID
        ) else { return }
        // A hardRefresh() may have started or finished while this was in
        // flight: switching into the Home tab fires a soft refresh, and an
        // immediate double-tap of the VoiceOver refresh button fires a hard
        // one. `refreshGeneration` only advances, so if it moved, the hard
        // refresh's fresher and more complete data has landed — defer to it.
        guard generation == refreshGeneration else { return }
        // Whether this reaches the screen depends on `MediaItem.==` being
        // structural — see its doc comment. It is not a scheduling concern;
        // resist adding a yield or a run-loop hop here.
        curatedRails = mergeGuardingAgainstPlaybackRegression(result)
    }

    /// Re-fetches everything on Home — hero banner, libraries, curated rails
    /// and a reshuffled set of dynamic rails — without blanking the page:
    /// `loadState` stays `.loaded` throughout, unlike
    /// `load()`/`retryLoadIfNeeded()`. Called by `HomeView`'s pull-to-refresh
    /// and its VoiceOver-only refresh button.
    ///
    /// No-ops before the first `load()` succeeds. A failure leaves what's on
    /// screen in place rather than erroring out the whole page (see
    /// `performFullLoad(resetLoadState:)`'s catch). Concurrent callers
    /// coalesce via `inFlightHardRefresh`.
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

    /// Re-runs dynamic rail discovery on a `ConnectivityMonitor` transition
    /// back online, only if the last attempt failed — so a library with no
    /// dynamic rails to offer, or a successful attempt, isn't re-fetched. The
    /// re-run repeats all six discovery calls (nothing here records which
    /// ones failed), which `loadDynamicRailCandidates()`'s
    /// `consumedDynamicRailCandidates` filtering makes safe.
    func retryDynamicRailCandidatesIfNeeded() async {
        guard dynamicRailCandidatesFailed else { return }
        dynamicRailCandidatesFailed = false
        await loadDynamicRailCandidates()
    }

    /// Fetches the next `dynamicRailBatchSize` candidates concurrently and
    /// appends whichever clear `minimumDynamicRailItemCount` — called by
    /// `loadDynamicRailCandidates` for the first batch and by `HomeView`'s
    /// scroll sentinel for the rest. A candidate that fails or comes back too
    /// sparse is dropped rather than shown as a barely-populated rail.
    func loadMoreDynamicRails() async {
        guard !isLoadingMoreDynamicRails, !pendingDynamicRailCandidates.isEmpty else { return }
        isLoadingMoreDynamicRails = true
        defer { isLoadingMoreDynamicRails = false }

        let batch = Array(pendingDynamicRailCandidates.prefix(Self.dynamicRailBatchSize))
        pendingDynamicRailCandidates.removeFirst(batch.count)
        hasMoreDynamicRails = !pendingDynamicRailCandidates.isEmpty

        let images = await client.makeImageURLBuilder()
        // Read on the actor and captured by value, since the task group's
        // child tasks run outside `HomeViewModel`'s `@MainActor` isolation and
        // its static members are isolated too.
        let minimumItemCount = Self.minimumDynamicRailItemCount
        let moviesLibraryID = self.moviesLibraryID
        let showsLibraryID = self.showsLibraryID
        let itemShuffle = self.itemShuffle
        // Tagged with its index in `batch` to restore the batch's
        // already-shuffled order, which task-group completion order doesn't
        // preserve. Each result carries its candidate back out so the ones
        // that produced a rail can be recorded into
        // `consumedDynamicRailCandidates`.
        let fetched = await withTaskGroup(of: (Int, DynamicRailCandidate, MediaCollectionRail?).self) { group in
            for (index, candidate) in batch.enumerated() {
                group.addTask { [client, userID, itemShuffle] in
                    // `SortBy=Random` samples the candidate's entire matching
                    // set. Without it `limit: 16` defaults to
                    // `SortBy=SortName`, capping every rail to the
                    // alphabetically-first 16 matches forever — a large genre
                    // would only ever show A-through-D titles, since the
                    // client-side shuffle below can only reorder what the
                    // server returned.
                    //
                    // An earlier attempt at this call was abandoned after a
                    // report of zero dynamic rails on a real library, which
                    // may have been the `ScrollBottomObserver` attach race
                    // fixed in the same pass. Hence the fallback to the old
                    // behavior (alphabetical, same cap) whenever the
                    // random-sorted attempt fails or comes back under
                    // `minimumItemCount` — indistinguishable from a candidate
                    // that genuinely has fewer items, so retrying is safe.
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
                    // Shuffled client-side even on the random-sorted path: a
                    // cheap hedge against a weak or session-cached server
                    // "random", and the only thing that reorders the
                    // fallback path's result.
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

        // Appended once from a local array rather than per-rail inside the
        // loop: `dynamicRails` is `@Observable` and backs `HomeView`'s
        // `LazyVStack`, so each append fires its own layout flush over the
        // whole rail list. Up to `dynamicRailBatchSize` (5) of those
        // back-to-back while the user is scrolling was a plausible
        // contributor to an intermittent real-device freeze here — see
        // `home-collection-nav-freeze-unconfirmed` memory, occurrence 3.
        let newRails = fetched.compactMap { _, candidate, rail in
            rail.map { (candidate, $0) }
        }
        dynamicRails.append(contentsOf: newRails.map(\.1))
        for (candidate, _) in newRails {
            consumedDynamicRailCandidates.insert(candidate)
        }
    }
}
