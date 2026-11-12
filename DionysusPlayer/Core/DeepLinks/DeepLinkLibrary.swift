import Foundation

/// The grid a `dionysus://library/<id>` link opens (#406): the same query
/// Home's library rail and the Apple TV's sidebar open that library with,
/// seeded with the link's sort and facets.
enum DeepLinkLibrary {
    /// What the app says when the link's library isn't one of the user's
    /// (unknown, hidden from them, or a music library, which the app
    /// doesn't browse).
    static var notFoundMessage: String { String(localized: "This library can't be found.") }

    /// `library`'s grid, as the link asks for it.
    static func query(for library: MediaItem, options: DeepLink.LibraryOptions) -> CollectionQuery {
        var query = CollectionQuery(title: library.name, parentID: library.id, includeItemTypes: library.libraryContentItemTypes)
        if let sort = options.sort { query.initialSortField = sort }
        if let order = options.order { query.initialSortOrder = order }
        query.initialGenre = options.genre
        query.initialStudio = options.studio
        switch options.filter {
        case .favorites: query.initialFavoriteStatus = .favorite
        case .watched: query.initialWatchStatus = .watched
        case .unwatched: query.initialWatchStatus = .unwatched
        case nil: break
        }
        return query
    }

    /// The library with that id among the user's, as the app lists them
    /// (music left out); nil when it isn't there.
    static func library(id: String, in libraries: [MediaItem]) -> MediaItem? {
        libraries.first { $0.id == id && !$0.isAudioLibrary }
    }

    /// Fetches the user's libraries and finds the link's; nil when it isn't
    /// one of them or the list can't be fetched.
    static func resolve(id: String, client: JellyfinAPIClient, userID: String) async -> MediaItem? {
        guard let views = try? await client.userViews(userID: userID) else { return nil }
        let images = await client.makeImageURLBuilder()
        return library(id: id, in: views.items.map { MediaItem(dto: $0, images: images) })
    }
}

extension DeepLink.Issue {
    /// What a library link says about a part it couldn't read; nil for a
    /// part that isn't about a library's grid.
    var libraryNotice: String? {
        switch self {
        case .unknownSort: String(localized: "Couldn't read the sort.")
        case .unknownOrder: String(localized: "Couldn't read the order.")
        case .unknownFilter: String(localized: "Couldn't read the filter.")
        case .unreadableStartTime, .unreadableChapter, .unreadableAudio, .unreadableSubtitle,
             .unknownSection, .unknownMode, .unreadableBitrate: nil
        }
    }
}
