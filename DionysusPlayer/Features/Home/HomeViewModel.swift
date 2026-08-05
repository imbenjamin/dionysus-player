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
    /// Everything else: Continue Watching, Recently Added Movies, Recently
    /// Added Shows, in that order — omitted when empty.
    private(set) var rails: [MediaCollectionRail] = []
    private(set) var loadState: LoadState = .idle

    private let client: JellyfinAPIClient
    private let userID: String

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    /// Populates Home's rails. Deliberately simple — real rail selection
    /// (what shows, in what order) is expected to be redesigned later.
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
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong loading your library.")
        }
    }
}
