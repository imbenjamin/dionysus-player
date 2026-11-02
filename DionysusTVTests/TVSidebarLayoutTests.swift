import XCTest
@testable import Dionysus

/// The sidebar lists each library as its own entry up to five, and folds them
/// into one "Libraries" entry above that (decided 2026-09-29), counting only
/// what's shown: a Music library is suppressed app-wide.
final class TVSidebarLayoutTests: XCTestCase {
    private func library(_ id: String, _ type: String?) -> MediaItem {
        let dto = BaseItemDto(id: id, name: id, type: .collectionFolder, collectionType: type)
        return MediaItem(dto: dto, images: ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil))
    }

    /// Collapsed, VoiceOver read every dimmed row after each tile, so a row
    /// that can't take focus is hidden from it then; open, nothing is (M5).
    /// XCUITest lists these rows whatever their hidden state, so this rule is
    /// pinned here and heard with VoiceOver.
    func test_collapsed_hidesOnlyTheRowsThatCantTakeFocus() {
        let focusable: Set<TVSidebarLayout.Row> = [.home]
        XCTAssertFalse(TVSidebarLayout.isHiddenFromAccessibility(.home, isExpanded: false, focusable: focusable))
        XCTAssertTrue(TVSidebarLayout.isHiddenFromAccessibility(.search, isExpanded: false, focusable: focusable))
        XCTAssertTrue(TVSidebarLayout.isHiddenFromAccessibility(.profile, isExpanded: false, focusable: focusable))
        XCTAssertFalse(TVSidebarLayout.isHiddenFromAccessibility(.search, isExpanded: true, focusable: focusable), "Open, every row is read")
    }

    func test_noLibraries_addsNoEntries() {
        XCTAssertEqual(TVSidebarLayout.libraries([]), .none)
    }

    func test_fiveLibraries_stayInline() {
        let five = (1...5).map { library("l\($0)", "movies") }
        XCTAssertEqual(TVSidebarLayout.libraries(five), .inline(five))
    }

    func test_sixLibraries_fold() {
        let six = (1...6).map { library("l\($0)", "movies") }
        XCTAssertEqual(TVSidebarLayout.libraries(six), .folded(six))
    }

    /// Five video libraries and a Music one: the Music one is dropped first,
    /// so five remain and nothing folds.
    func test_musicLibrary_isDroppedBeforeCounting() {
        let five = (1...5).map { library("l\($0)", "movies") }
        let music = library("music", JellyfinCollectionType.music)
        XCTAssertEqual(TVSidebarLayout.libraries(five + [music]), .inline(five))
    }

    func test_symbols_coverEveryKnownCollectionType_andFallBack() {
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.movies), "film")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.tvShows), "tv")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.boxSets), "square.stack")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.playlists), "list.bullet.rectangle")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "homevideos"), "video")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "musicvideos"), "music.note.tv")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "photos"), "photo.on.rectangle")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "books"), "book")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "livetv"), "dot.radiowaves.left.and.right")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "mixed"), "folder")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: nil), "folder")
    }

    func test_query_opensTheLibraryWithItsContentTypes() {
        let movies = library("lib-movies", JellyfinCollectionType.movies)
        let query = TVSidebarLayout.query(for: movies)
        XCTAssertEqual(query.parentID, "lib-movies")
        XCTAssertEqual(query.includeItemTypes, movies.libraryContentItemTypes)
    }

    // MARK: - Row order (Task 6b)

    /// Profile is pinned at the top, above Home and Search (as in Apple's TV
    /// app), then one row per library.
    func test_rows_profileFirst_thenHomeSearch_thenEachLibrary() {
        let four = (1...4).map { library("l\($0)", "movies") }
        XCTAssertEqual(
            TVSidebarLayout.rows(libraries: four, librariesExpanded: false),
            [.profile, .home, .search, .library("l1"), .library("l2"), .library("l3"), .library("l4")]
        )
    }

    /// Above five, the libraries hide behind one Libraries row, collapsed
    /// until it's selected.
    func test_rows_folded_showOnlyTheGroupRow_untilExpanded() {
        let six = (1...6).map { library("l\($0)", "movies") }
        XCTAssertEqual(TVSidebarLayout.rows(libraries: six, librariesExpanded: false), [.profile, .home, .search, .librariesGroup])
        XCTAssertEqual(
            TVSidebarLayout.rows(libraries: six, librariesExpanded: true),
            [.profile, .home, .search, .librariesGroup] + six.map { .library($0.id) }
        )
    }

    func test_rows_noLibraries_isJustProfileHomeSearch() {
        XCTAssertEqual(TVSidebarLayout.rows(libraries: [], librariesExpanded: true), [.profile, .home, .search])
    }
}
