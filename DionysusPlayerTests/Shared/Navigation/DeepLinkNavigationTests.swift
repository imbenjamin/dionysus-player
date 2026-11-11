import XCTest
@testable import Dionysus

/// Where each `dionysus://` destination lands on iPhone and iPad (#406).
final class DeepLinkNavigationTests: XCTestCase {
    func test_places_selectTheirTab() {
        XCTAssertEqual(DeepLinkNavigation.plan(for: .home), .init(tab: .home, homePath: []))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .downloads), .init(tab: .downloads))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .profile(path: [])), .init(tab: .profile))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .profile(path: ["about"])), .init(tab: .profile))
    }

    func test_search_fillsTheQuery_orJustOpensSearch() {
        XCTAssertEqual(DeepLinkNavigation.plan(for: .search(query: "Aurora")), .init(tab: .search, searchQuery: "Aurora"))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .search(query: nil)), .init(tab: .search))
    }

    func test_item_replacesHomesStackWithThePage() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .item(id: "m1", options: .init())),
            .init(tab: .home, homePath: [.assetDetail(itemID: "m1")])
        )
    }

    func test_play_pushesThePage_andCuesItToPlay() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m1", options: .init())),
            .init(tab: .home, homePath: [.assetDetail(itemID: "m1")], playsItemID: "m1")
        )
    }

    func test_destinationsNotOpenedYet_planNothing() {
        XCTAssertNil(DeepLinkNavigation.plan(for: .library(id: "l", options: .init())))
        XCTAssertNil(DeepLinkNavigation.plan(for: .downloaded(id: "m1")))
        XCTAssertNil(DeepLinkNavigation.plan(for: .quickConnectApproval(code: nil)))
        XCTAssertNil(DeepLinkNavigation.plan(for: .serverSetup(address: "http://x")))
    }
}
