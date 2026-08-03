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

    private(set) var rails: [HomeRail] = []
    private(set) var loadState: LoadState = .idle

    private let client: JellyfinAPIClient
    private let userID: String

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    func loadIfNeeded() async {
        guard rails.isEmpty else { return }
        await load()
    }

    /// Populates a first pass of Home rails. Deliberately simple — real
    /// rail selection (what shows, in what order) is expected to be
    /// redesigned later.
    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()

            let views = try await client.userViews(userID: userID)
            let moviesLibraryID = views.items.first { $0.collectionType == "movies" }?.id
            let showsLibraryID = views.items.first { $0.collectionType == "tvshows" }?.id

            async let resume = client.resumeItems(userID: userID)
            async let latestMovies = client.latestItems(userID: userID, parentID: moviesLibraryID, limit: 16)
            async let latestShows = client.latestItems(userID: userID, parentID: showsLibraryID, limit: 16)
            async let boxSets = client.items(userID: userID, includeItemTypes: ["BoxSet"], limit: 16)

            var newRails: [HomeRail] = []
            func appendRail(
                _ title: String,
                _ category: HomeCategory?,
                _ dtos: [BaseItemDto],
                seeAllQuery: CollectionQuery? = nil
            ) {
                guard !dtos.isEmpty else { return }
                let items = dtos.map { MediaItem(dto: $0, images: images) }
                let rail = MediaCollectionRail(title: title, items: items, seeAllQuery: seeAllQuery)
                newRails.append(HomeRail(category: category, rail: rail))
            }

            appendRail("Continue Watching", nil, try await resume.items)
            appendRail(
                "Recently Added Movies", .movies, try await latestMovies,
                seeAllQuery: CollectionQuery(title: "Movies", parentID: moviesLibraryID, includeItemTypes: ["Movie"])
            )
            appendRail(
                "Recently Added Series", .series, try await latestShows,
                seeAllQuery: CollectionQuery(title: "Series", parentID: showsLibraryID, includeItemTypes: ["Series"])
            )
            appendRail(
                "Collections", .collections, try await boxSets.items,
                seeAllQuery: CollectionQuery(title: "Collections", includeItemTypes: ["BoxSet"])
            )

            rails = newRails
            loadState = .loaded
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong loading your library.")
        }
    }
}
