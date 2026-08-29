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
    /// `load()`.
    private(set) var heroItems: [MediaItem] = []
    /// The user's own libraries (Movies, Shows, Collections, ...), for the
    /// rail that replaced the old top-menu category picker.
    private(set) var libraries: [MediaItem] = []
    /// Curated rails (Continue Watching, Next Up, Recently Added Movies,
    /// Recently Added Shows, in that order — omitted when empty) followed
    /// by however many dynamic rails (genres, studios/networks, actors,
    /// directors — see `DynamicRailCandidate`) have loaded so far via
    /// `loadDynamicRailCandidates`/`loadMoreDynamicRails`. Both kinds live
    /// in the same array/order since `HomeView` just renders it straight
    /// through — the dynamic ones are simply appended after `load()`
    /// finishes the curated set.
    private(set) var rails: [MediaCollectionRail] = []
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
    /// Resolved once by `load()`, reused by both the curated rails' own
    /// `seeAllQuery`s and (via `DynamicRailCandidate.seeAllQuery`)
    /// `loadMoreDynamicRails`' — stored rather than a `load()`-local `let`
    /// since `loadMoreDynamicRails` is also called independently later, from
    /// `HomeView`'s scroll-triggered sentinel, long after `load()`'s own
    /// locals are out of scope.
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
    static let defaultReconnectRetrySchedule: [Double] = [1.0, 2.0, 4.0, 8.0]

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

    /// Populates Home's curated rails, then kicks off dynamic genre/studio
    /// rail discovery (`loadDynamicRailCandidates`) once they're showing —
    /// `loadState` flips to `.loaded` as soon as the curated set is ready,
    /// deliberately not waiting on genre/studio discovery too, so Home
    /// doesn't feel slower because of it. A failure in that follow-on step
    /// doesn't affect `loadState`; Home stays usable without the extra
    /// rails rather than erroring out entirely over them.
    func load() async {
        loadState = .loading
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
            // AUDIO SUPPRESSION: excludeItemTypes keeps audio/music out of
            // Continue Watching server-side — see `JellyfinAPIClient
            // .audioItemTypeExclusions`'s doc comment. Delete this argument
            // once Dionysus Player supports audio/music playback.
            async let resume = client.resumeItems(userID: userID, excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions)
            async let upNext = client.nextUp(userID: userID, limit: 16)
            async let latestMovies = client.latestItems(userID: userID, parentID: moviesLibraryID, limit: 16)
            async let latestShows = client.latestItems(userID: userID, parentID: showsLibraryID, limit: 16)

            heroItems = try await heroCandidates.items.map { MediaItem(dto: $0, images: images) }
            // AUDIO SUPPRESSION: `/Users/{id}/Views` has no server-side type
            // filter, so a Music library has to be dropped here instead —
            // see `MediaItem.isAudioLibrary`'s doc comment. Delete this
            // `.filter` once Dionysus Player supports browsing a Music
            // library.
            libraries = views.items
                .map { MediaItem(dto: $0, images: images) }
                .filter { !$0.isAudioLibrary }

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

            rails = newRails
            loadState = .loaded

            await loadDynamicRailCandidates()
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Something went wrong loading your library.")
            )
        }
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
    /// connectivity-triggered retry re-runs it wholesale — see
    /// `retryDynamicRailCandidatesIfNeeded()`), so candidates already
    /// represented by a rail (`consumedDynamicRailCandidates`) are filtered
    /// out before the fresh discovery results get queued, or a retry would
    /// re-append rails that are already showing.
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
    func retryLoadIfNeeded() async {
        guard loadState != .loaded else { return }
        let delays = [0.0] + reconnectRetrySchedule
        for (index, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await load()
            if loadState == .loaded { return }
            if index < delays.count - 1 { loadState = .loading }
        }
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
        // calling `rails.append(rail)` inside the loop — `rails` is an
        // `@Observable` property that `HomeView` reads to build its
        // `LazyVStack` of rails, so each separate append used to fire its
        // own SwiftUI transaction/layout flush over the whole rail list.
        // Landing up to `dynamicRailBatchSize` (5) of those back-to-back,
        // right as `HomeView`'s scroll-triggered sentinel fires (i.e. while
        // the user is actively scrolling), was a plausible contributor to
        // an intermittently-reported real-device freeze in this exact
        // region — see `home-collection-nav-freeze-unconfirmed` memory,
        // occurrence 3. One append means one flush instead of up to five.
        let newRails = fetched.compactMap { _, candidate, rail in
            rail.map { (candidate, $0) }
        }
        rails.append(contentsOf: newRails.map(\.1))
        for (candidate, _) in newRails {
            consumedDynamicRailCandidates.insert(candidate)
        }
    }
}
