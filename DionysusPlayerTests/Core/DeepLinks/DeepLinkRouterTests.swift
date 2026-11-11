import XCTest
@testable import Dionysus

final class DeepLinkRouterTests: XCTestCase {
    private let server = "http://jf.local"

    private func decide(
        _ link: DeepLink,
        restoring: Bool = false,
        signedIn: Bool = true,
        serverID: String? = "http://jf.local",
        userID: String? = "u1"
    ) -> DeepLinkRouter.Decision {
        DeepLinkRouter.decide(link, isRestoringSession: restoring, isSignedIn: signedIn, serverID: serverID, userID: userID)
    }

    func test_waitsWhileTheSessionRestores() {
        XCTAssertEqual(decide(DeepLink(.home), restoring: true, signedIn: false, serverID: nil, userID: nil), .wait)
    }

    func test_refusesWhenSignedOut() {
        XCTAssertEqual(decide(DeepLink(.home), signedIn: false, userID: nil), .refuse(.signedOut))
    }

    func test_refusesALinkForAnotherServer_orUser() {
        XCTAssertEqual(decide(DeepLink(.home, serverID: "http://other")), .refuse(.otherServer))
        XCTAssertEqual(decide(DeepLink(.home, userID: "u2")), .refuse(.otherUser))
    }

    func test_appliesALinkThatNamesNoServerOrUser_orTheSignedInOnes() {
        XCTAssertEqual(decide(DeepLink(.item(id: "m1", options: .init()))), .apply)
        XCTAssertEqual(decide(DeepLink(.item(id: "m1", options: .init()), serverID: server, userID: "u1")), .apply)
    }

    /// A link takes a few awaits to apply (the closing player, the item's
    /// fetch); a sign-out in between, as Who's Watching? on return, or
    /// another user signed in, ends it (M6 review).
    func test_aLinkBeingApplied_finishesOnlyForTheSameSignedInUser() {
        XCTAssertTrue(DeepLinkRouter.canFinish(appliedFor: "u1", isSignedIn: true, signedInUserID: "u1"))
        XCTAssertFalse(DeepLinkRouter.canFinish(appliedFor: "u1", isSignedIn: false, signedInUserID: "u1"))
        XCTAssertFalse(DeepLinkRouter.canFinish(appliedFor: "u1", isSignedIn: true, signedInUserID: "u2"))
        XCTAssertFalse(DeepLinkRouter.canFinish(appliedFor: "u1", isSignedIn: true, signedInUserID: nil))
    }
}
