import XCTest
@testable import Dionysus

/// The grid a `dionysus://library` link opens (#406).
@MainActor
final class DeepLinkLibraryTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func library(_ id: String, _ type: String?) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: id, name: "Library \(id)", type: .collectionFolder, collectionType: type), images: images)
    }

    /// With no options, the same query the library's rail tile opens.
    func test_query_withNoOptions_isTheRailsQuery() {
        let movies = library("lib-m", "movies")
        XCTAssertEqual(
            DeepLinkLibrary.query(for: movies, options: .init()),
            CollectionQuery(title: "Library lib-m", parentID: "lib-m", includeItemTypes: ["Movie"])
        )
    }

    func test_query_seedsSortOrderGenreAndStudio() {
        let options = DeepLink.LibraryOptions(sort: .dateAdded, order: .descending, genre: "Sci-Fi & Fantasy", studio: "HBO")
        let query = DeepLinkLibrary.query(for: library("lib-s", "tvshows"), options: options)
        XCTAssertEqual(query.includeItemTypes, ["Series"])
        XCTAssertEqual(query.initialSortField, .dateAdded)
        XCTAssertEqual(query.initialSortOrder, .descending)
        XCTAssertEqual(query.initialGenre, "Sci-Fi & Fantasy")
        XCTAssertEqual(query.initialStudio, "HBO")
    }

    func test_query_mapsEachFilterToItsFacet() {
        let movies = library("lib-m", "movies")
        let favorites = DeepLinkLibrary.query(for: movies, options: .init(filter: .favorites))
        XCTAssertEqual(favorites.initialFavoriteStatus, .favorite)
        XCTAssertNil(favorites.initialWatchStatus)
        XCTAssertEqual(DeepLinkLibrary.query(for: movies, options: .init(filter: .watched)).initialWatchStatus, .watched)
        XCTAssertEqual(DeepLinkLibrary.query(for: movies, options: .init(filter: .unwatched)).initialWatchStatus, .unwatched)
    }

    /// A music library isn't browsable, so a link to one finds nothing.
    func test_library_findsTheUsersLibrary_butNotMusic() {
        let libraries = [library("lib-m", "movies"), library("lib-a", "music")]
        XCTAssertEqual(DeepLinkLibrary.library(id: "lib-m", in: libraries)?.id, "lib-m")
        XCTAssertNil(DeepLinkLibrary.library(id: "lib-a", in: libraries))
        XCTAssertNil(DeepLinkLibrary.library(id: "nope", in: libraries))
    }

    func test_resolve_asksForTheUsersViews() async {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        let dto = BaseItemDto(id: "lib-m", name: "Movies", type: .collectionFolder, collectionType: "movies")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/Users/user-1/Views")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [dto], totalRecordCount: 1))
        }
        let found = await DeepLinkLibrary.resolve(id: "lib-m", client: client, userID: "user-1")
        XCTAssertEqual(found?.name, "Movies")
        let missing = await DeepLinkLibrary.resolve(id: "lib-x", client: client, userID: "user-1")
        XCTAssertNil(missing)
    }

    func test_resolve_failingToAsk_findsNothing() async {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let found = await DeepLinkLibrary.resolve(id: "lib-m", client: client, userID: "user-1")
        XCTAssertNil(found)
    }

    func test_libraryNotices_sayWhatCouldntBeRead() {
        XCTAssertEqual(DeepLink.Issue.unknownSort.libraryNotice, "Couldn't read the sort.")
        XCTAssertEqual(DeepLink.Issue.unknownOrder.libraryNotice, "Couldn't read the order.")
        XCTAssertEqual(DeepLink.Issue.unknownFilter.libraryNotice, "Couldn't read the filter.")
        XCTAssertNil(DeepLink.Issue.unreadableStartTime.libraryNotice)
    }
}

/// The pages a `dionysus://profile` link's path names (#406).
final class DeepLinkProfilePageTests: XCTestCase {
    func test_eachPathNamesItsPage() {
        let pages: [[String]: DeepLink.ProfilePage] = [
            []: .root, ["account"]: .account, ["appearance"]: .appearance, ["playback"]: .playback,
            ["playback", "advanced"]: .advancedPlayback, ["downloads"]: .downloads, ["about"]: .about,
            ["about", "license"]: .license, ["about", "privacy"]: .privacyPolicy,
        ]
        for (path, page) in pages {
            XCTAssertEqual(DeepLink.ProfilePage(path: path), page, "\(path)")
        }
    }

    func test_caseDoesntMatter() {
        XCTAssertEqual(DeepLink.ProfilePage(path: ["About", "License"]), .license)
    }

    func test_aPageProfileDoesntHave_isNil() {
        XCTAssertNil(DeepLink.ProfilePage(path: ["nope"]))
        XCTAssertNil(DeepLink.ProfilePage(path: ["appearance", "advanced"]))
        XCTAssertNil(DeepLink.ProfilePage(path: ["account", "quickconnect"]))
    }
}
