import XCTest
@testable import Dionysus

final class TVSearchGroupingTests: XCTestCase {
    private func result(_ id: String, _ kind: BaseItemKind?) throws -> SearchResult {
        // `SearchResult` is built from a hint or decoded; decoding lets a
        // test set `kind` to nil, as old history entries have it.
        var json: [String: Any] = ["id": id, "name": id]
        if let kind { json["kind"] = kind.rawValue }
        return try JSONDecoder().decode(SearchResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_sections_comeInAFixedOrder_whateverOrderTheServerSent() throws {
        let results = [try result("e", .episode), try result("b", .boxSet), try result("m", .movie), try result("s", .series), try result("p", .playlist)]
        XCTAssertEqual(TVSearchGrouping.sections(results).map(\.id), ["movies", "shows", "episodes", "collections", "playlists"])
    }

    func test_withinASection_theServersOrderIsKept() throws {
        let results = [try result("m2", .movie), try result("s1", .series), try result("m1", .movie)]
        XCTAssertEqual(TVSearchGrouping.sections(results).first?.results.map(\.id), ["m2", "m1"])
    }

    func test_emptySections_areLeftOut() throws {
        XCTAssertEqual(TVSearchGrouping.sections([try result("m", .movie)]).map(\.id), ["movies"])
        XCTAssertTrue(TVSearchGrouping.sections([]).isEmpty)
    }

    /// A kind with no rail of its own, or none at all, still shows: nothing
    /// the server returned is dropped.
    func test_otherKinds_andUnknownKinds_goUnderOther() throws {
        let results = [try result("x", nil), try result("y", .season), try result("m", .movie)]
        let sections = TVSearchGrouping.sections(results)
        XCTAssertEqual(sections.map(\.id), ["movies", "other"])
        XCTAssertEqual(sections.last?.results.map(\.id), ["x", "y"])
    }
}
