import XCTest
@testable import Dionysus

/// The sidebar's Profile entry names who is signed in. A launch resumed from
/// cache while the server is unreachable has no `currentUser` yet, and must
/// still show the stored account, never a blank or generic row.
final class TVProfileIdentityTests: XCTestCase {
    func test_prefersTheLiveUser() {
        let live = UserDto(id: "u1", name: "Benjamin", hasPassword: true, primaryImageTag: "tag")
        let stored = StoredCredentials(username: "old-name", password: "pw", accessToken: "t", userID: "u1")
        XCTAssertEqual(TVProfileIdentity.user(currentUser: live, credentials: stored), live)
    }

    func test_fallsBackToTheStoredAccountOffline() {
        let stored = StoredCredentials(username: "Benjamin", password: "pw", accessToken: "t", userID: "u1")
        let user = TVProfileIdentity.user(currentUser: nil, credentials: stored)
        XCTAssertEqual(user?.id, "u1")
        XCTAssertEqual(user?.name, "Benjamin")
        XCTAssertNil(user?.primaryImageTag, "No tag offline: the avatar shows the monogram")
    }

    func test_nothingStored_isNil() {
        XCTAssertNil(TVProfileIdentity.user(currentUser: nil, credentials: nil))
    }
}
