import XCTest
@testable import Dionysus

/// The Top Shelf's links (M6): `dionysus://item|play/<id>?server=<id>`.
final class TVDeepLinkTests: XCTestCase {
    private let server = "http://jellyfin.local:8096"

    func test_url_roundTrips_forBothActions() {
        for action in [TVDeepLink.Action.item, .play] {
            let link = TVDeepLink(action: action, itemID: "abc123", serverID: server)
            XCTAssertEqual(TVDeepLink(url: link.url), link)
        }
    }

    func test_url_isTheDocumentedShape() {
        let link = TVDeepLink(action: .play, itemID: "abc123", serverID: server)
        XCTAssertEqual(link.url.scheme, "dionysus")
        XCTAssertEqual(link.url.host(), "play")
        XCTAssertEqual(link.url.path(), "/abc123")
    }

    func test_parse_rejectsOtherSchemesActionsAndMissingParts() {
        XCTAssertNil(TVDeepLink(url: URL(string: "https://item/abc?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://delete/abc?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://item/?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://item/abc")!))
    }
}
