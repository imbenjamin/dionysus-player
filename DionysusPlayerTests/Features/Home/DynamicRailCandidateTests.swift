import XCTest
@testable import Dionysus

/// `DynamicRailCandidate.railTitle` is pure formatting logic, cheap to pin
/// down directly — see `HomeViewModelTests` for the networking/discovery
/// side of Home's dynamic rails.
final class DynamicRailCandidateTests: XCTestCase {
    func test_railTitle_movieGenre() {
        XCTAssertEqual(DynamicRailCandidate.genre(kind: .movie, name: "Action").railTitle, "Action Movies")
    }

    func test_railTitle_showGenre() {
        XCTAssertEqual(DynamicRailCandidate.genre(kind: .series, name: "Documentary").railTitle, "Documentary Shows")
    }

    func test_railTitle_movieStudio() {
        XCTAssertEqual(DynamicRailCandidate.studio(kind: .movie, name: "Marvel Studios").railTitle, "Movies from Marvel Studios")
    }

    func test_railTitle_showStudio() {
        XCTAssertEqual(DynamicRailCandidate.studio(kind: .series, name: "HBO").railTitle, "Shows from HBO")
    }

    func test_railTitle_actor() {
        XCTAssertEqual(DynamicRailCandidate.actor(name: "Tom Hanks").railTitle, "Starring Tom Hanks")
    }

    func test_railTitle_director() {
        XCTAssertEqual(DynamicRailCandidate.director(name: "Christopher Nolan").railTitle, "Directed by Christopher Nolan")
    }

    // MARK: seeAllQuery

    func test_seeAllQuery_movieGenre_scopesToMoviesLibraryWithGenrePreset() {
        let query = DynamicRailCandidate.genre(kind: .movie, name: "Action")
            .seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows")

        XCTAssertEqual(query?.title, "Movies")
        XCTAssertEqual(query?.parentID, "lib-movies")
        XCTAssertEqual(query?.includeItemTypes, ["Movie"])
        XCTAssertEqual(query?.initialGenre, "Action")
        XCTAssertNil(query?.initialStudio)
    }

    func test_seeAllQuery_showGenre_scopesToShowsLibraryWithGenrePreset() {
        let query = DynamicRailCandidate.genre(kind: .series, name: "Documentary")
            .seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows")

        XCTAssertEqual(query?.title, "Shows")
        XCTAssertEqual(query?.parentID, "lib-shows")
        XCTAssertEqual(query?.includeItemTypes, ["Series"])
        XCTAssertEqual(query?.initialGenre, "Documentary")
    }

    func test_seeAllQuery_movieStudio_scopesToMoviesLibraryWithStudioPreset() {
        let query = DynamicRailCandidate.studio(kind: .movie, name: "Marvel Studios")
            .seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows")

        XCTAssertEqual(query?.title, "Movies")
        XCTAssertEqual(query?.parentID, "lib-movies")
        XCTAssertEqual(query?.includeItemTypes, ["Movie"])
        XCTAssertEqual(query?.initialStudio, "Marvel Studios")
        XCTAssertNil(query?.initialGenre)
    }

    func test_seeAllQuery_showStudio_scopesToShowsLibraryWithStudioPreset() {
        let query = DynamicRailCandidate.studio(kind: .series, name: "HBO")
            .seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows")

        XCTAssertEqual(query?.title, "Shows")
        XCTAssertEqual(query?.parentID, "lib-shows")
        XCTAssertEqual(query?.includeItemTypes, ["Series"])
        XCTAssertEqual(query?.initialStudio, "HBO")
    }

    /// Actor/director rails span both movies and shows at once, which
    /// doesn't map onto a single-library `CollectionQuery` — see
    /// `seeAllQuery`'s own doc comment.
    func test_seeAllQuery_actorAndDirector_areNil() {
        XCTAssertNil(DynamicRailCandidate.actor(name: "Tom Hanks").seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows"))
        XCTAssertNil(
            DynamicRailCandidate.director(name: "Christopher Nolan")
                .seeAllQuery(moviesLibraryID: "lib-movies", showsLibraryID: "lib-shows")
        )
    }

    func test_seeAllQuery_nilLibraryIDsStillProducesAQuery() {
        // A library ID being nil (e.g. genuinely no Movies library on this
        // server) shouldn't suppress the See All link entirely — it should
        // still filter correctly, just without a parent scope.
        let query = DynamicRailCandidate.genre(kind: .movie, name: "Action")
            .seeAllQuery(moviesLibraryID: nil, showsLibraryID: nil)
        XCTAssertNotNil(query)
        XCTAssertNil(query?.parentID)
    }
}
