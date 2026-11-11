import XCTest
@testable import Dionysus

final class DeepLinkRouterTests: XCTestCase {
    private let server = "http://jf.local"
    private let arrival = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func decide(
        _ link: DeepLink,
        after seconds: TimeInterval = 0,
        serverAtArrival: String? = "http://jf.local",
        restoring: Bool = false,
        signedIn: Bool = true,
        serverID: String? = "http://jf.local",
        userID: String? = "u1"
    ) -> DeepLinkRouter.Decision {
        DeepLinkRouter.decide(
            PendingDeepLink(link: link, receivedAt: arrival, serverIDAtArrival: serverAtArrival),
            now: arrival.addingTimeInterval(seconds),
            isRestoringSession: restoring, isSignedIn: signedIn, serverID: serverID, userID: userID
        )
    }

    func test_waitsWhileTheSessionRestores() {
        XCTAssertEqual(decide(DeepLink(.home), restoring: true, signedIn: false, serverID: nil, userID: nil), .wait)
    }

    /// Signed out, a link waits through sign-in rather than being dropped.
    func test_holdsALinkWhileSignedOut() {
        XCTAssertEqual(decide(DeepLink(.home), signedIn: false, userID: nil), .waitForSignIn)
        XCTAssertEqual(decide(DeepLink(.home), serverAtArrival: nil, signedIn: false, serverID: nil, userID: nil), .waitForSignIn)
    }

    func test_aHeldLink_expiresAfterTenMinutes() {
        XCTAssertEqual(decide(DeepLink(.home), after: 600, signedIn: false), .waitForSignIn)
        XCTAssertEqual(decide(DeepLink(.home), after: 600), .apply)
        XCTAssertEqual(decide(DeepLink(.home), after: 601, signedIn: false), .refuse(.expired))
        XCTAssertEqual(decide(DeepLink(.home), after: 601), .refuse(.expired))
    }

    /// A link with no server of its own, held while server setup moved to
    /// another server, isn't applied there.
    func test_aHeldLink_isDropped_whenTheServerChangesBeforeSignIn() {
        XCTAssertEqual(decide(DeepLink(.home), serverID: "http://other"), .refuse(.serverChanged))
        XCTAssertEqual(decide(DeepLink(.home), serverAtArrival: nil, serverID: "http://new"), .apply,
                       "A link that arrived before any server was set up applies to the one chosen")
    }

    func test_refusesALinkForAnotherServer_orUser() {
        XCTAssertEqual(decide(DeepLink(.home, serverID: "http://other")), .refuse(.otherServer))
        XCTAssertEqual(decide(DeepLink(.home, userID: "u2")), .refuse(.otherUser))
    }

    func test_appliesALinkThatNamesNoServerOrUser_orTheSignedInOnes() {
        XCTAssertEqual(decide(DeepLink(.item(id: "m1", options: .init()))), .apply)
        XCTAssertEqual(decide(DeepLink(.item(id: "m1", options: .init()), serverID: server, userID: "u1")), .apply)
    }

    func test_refusals_sayWhyOnlyWhenSomeoneIsStillWaiting() {
        XCTAssertEqual(DeepLinkRouter.Refusal.otherServer.message, "This link is for another server.")
        XCTAssertEqual(DeepLinkRouter.Refusal.otherUser.message, "This link is for another user.")
        XCTAssertNil(DeepLinkRouter.Refusal.expired.message)
        XCTAssertNil(DeepLinkRouter.Refusal.serverChanged.message)
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
