import XCTest
@testable import Dionysus

final class TVDeepLinkRouterTests: XCTestCase {
    private let link = TVDeepLink(action: .item, itemID: "m1", serverID: "http://jf.local")

    func test_waitsWhileTheSessionRestores() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: true, isSignedIn: false, serverID: nil), .wait)
    }

    func test_ignoresALinkWhenSignedOut_orForAnotherServer() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: false, serverID: "http://jf.local"), .ignore)
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: true, serverID: "http://other"), .ignore)
    }

    func test_itemOpensTheDetailPage_playPlaysIt() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: true, serverID: "http://jf.local"), .openDetail(itemID: "m1"))
        var play = link
        play.action = .play
        XCTAssertEqual(TVDeepLinkRouter.decide(play, isRestoringSession: false, isSignedIn: true, serverID: "http://jf.local"), .play(itemID: "m1"))
    }
}
