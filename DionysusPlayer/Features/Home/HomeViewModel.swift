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

    private static let dynamicRailBatchSize = 10
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

    private let client: JellyfinAPIClient
    private let userID: String
    /// Injected so tests can pin the "random" order deterministically (an
    /// identity closure) instead of a real shuffle. Defaults to a real
    /// shuffle for production use — every `load()` reshuffles, so the
    /// dynamic rails' order differs each time Home is freshly loaded.
    private let shuffle: ([DynamicRailCandidate]) -> [DynamicRailCandidate]

    init(
        client: JellyfinAPIClient,
        userID: String,
        shuffle: @escaping ([DynamicRailCandidate]) -> [DynamicRailCandidate] = { $0.shuffled() }
    ) {
        self.client = client
        self.userID = userID
        self.shuffle = shuffle
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
            let moviesLibraryID = views.items.first { $0.collectionType == "movies" }?.id
            let showsLibraryID = views.items.first { $0.collectionType == "tvshows" }?.id

            async let heroCandidates = client.items(
                userID: userID,
                includeItemTypes: ["Movie", "Series"],
                sortBy: "Random",
                filters: ["IsUnplayed"],
                limit: 10
            )
            async let resume = client.resumeItems(userID: userID)
            async let upNext = client.nextUp(userID: userID, limit: 16)
            async let latestMovies = client.latestItems(userID: userID, parentID: moviesLibraryID, limit: 16)
            async let latestShows = client.latestItems(userID: userID, parentID: showsLibraryID, limit: 16)

            heroItems = try await heroCandidates.items.map { MediaItem(dto: $0, images: images) }
            libraries = views.items.map { MediaItem(dto: $0, images: images) }

            var newRails: [MediaCollectionRail] = []
            func appendRail(_ title: String, _ dtos: [BaseItemDto], seeAllQuery: CollectionQuery? = nil) {
                guard !dtos.isEmpty else { return }
                let items = dtos.map { MediaItem(dto: $0, images: images) }
                newRails.append(MediaCollectionRail(title: title, items: items, seeAllQuery: seeAllQuery))
            }

            appendRail("Continue Watching", try await resume.items)
            appendRail("Next Up", try await upNext.items)
            appendRail(
                "Recently Added Movies", try await latestMovies,
                seeAllQuery: CollectionQuery(title: "Movies", parentID: moviesLibraryID, includeItemTypes: ["Movie"])
            )
            appendRail(
                "Recently Added Shows", try await latestShows,
                seeAllQuery: CollectionQuery(title: "Shows", parentID: showsLibraryID, includeItemTypes: ["Series"])
            )

            rails = newRails
            loadState = .loaded

            await loadDynamicRailCandidates()
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong loading your library.")
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
        if let items = try? await movieGenres.items {
            candidates += items.map { DynamicRailCandidate.genre(kind: .movie, name: $0.name) }
        }
        if let items = try? await showGenres.items {
            candidates += items.map { DynamicRailCandidate.genre(kind: .series, name: $0.name) }
        }
        if let items = try? await movieStudios.items {
            candidates += items.map { DynamicRailCandidate.studio(kind: .movie, name: $0.name) }
        }
        if let items = try? await showStudios.items {
            candidates += items.map { DynamicRailCandidate.studio(kind: .series, name: $0.name) }
        }
        if let items = try? await actors.items {
            candidates += items.map { DynamicRailCandidate.actor(name: $0.name) }
        }
        if let items = try? await directors.items {
            candidates += items.map { DynamicRailCandidate.director(name: $0.name) }
        }

        pendingDynamicRailCandidates = shuffle(candidates)
        hasMoreDynamicRails = !pendingDynamicRailCandidates.isEmpty
        await loadMoreDynamicRails()
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
        // Tagged with its index in `batch` so results can be restored to
        // the batch's (already-shuffled) order afterward — task-group
        // completion order isn't otherwise guaranteed to match it.
        let fetched = await withTaskGroup(of: (Int, MediaCollectionRail?).self) { group in
            for (index, candidate) in batch.enumerated() {
                group.addTask { [client, userID] in
                    let dtos: [BaseItemDto]?
                    switch candidate {
                    case .genre(let kind, let name):
                        dtos = try? await client.items(
                            userID: userID, includeItemTypes: [kind.rawValue], genres: [name], limit: 16
                        ).items
                    case .studio(let kind, let name):
                        dtos = try? await client.items(
                            userID: userID, includeItemTypes: [kind.rawValue], studios: [name], limit: 16
                        ).items
                    case .actor(let name):
                        dtos = try? await client.items(
                            userID: userID, includeItemTypes: ["Movie", "Series"],
                            person: name, personTypes: ["Actor"], limit: 16
                        ).items
                    case .director(let name):
                        dtos = try? await client.items(
                            userID: userID, includeItemTypes: ["Movie", "Series"],
                            person: name, personTypes: ["Director"], limit: 16
                        ).items
                    }
                    guard let dtos, dtos.count >= minimumItemCount else { return (index, nil) }
                    let items = dtos.map { MediaItem(dto: $0, images: images) }
                    return (index, MediaCollectionRail(title: candidate.railTitle, items: items))
                }
            }
            var results: [(Int, MediaCollectionRail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }

        rails += fetched
    }
}
