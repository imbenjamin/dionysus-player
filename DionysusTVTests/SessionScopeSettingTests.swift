import XCTest
@testable import Dionysus

/// The setting is one value for the whole Apple TV, stored where every Apple
/// TV user reads it, and on by default.
final class SessionScopeSettingTests: XCTestCase {
    override func tearDown() {
        KeychainStore.delete(forKey: "settings.followsAppleTVUsers", scope: .allUsers)
        super.tearDown()
    }

    func test_defaultsToFollowingAppleTVUsers() {
        XCTAssertTrue(SessionScopeSetting.followsAppleTVUsers)
        XCTAssertEqual(SessionScopeSetting.sessionScope, .currentUser)
    }

    func test_turnedOff_persistsInTheSharedKeychain() {
        SessionScopeSetting.set(false)
        XCTAssertFalse(SessionScopeSetting.followsAppleTVUsers)
        XCTAssertEqual(SessionScopeSetting.sessionScope, .allUsers)
        XCTAssertNotNil(KeychainStore.load(forKey: "settings.followsAppleTVUsers", scope: .allUsers))
    }

    func test_turnedBackOn_followsAgain() {
        SessionScopeSetting.set(false)
        SessionScopeSetting.set(true)
        XCTAssertTrue(SessionScopeSetting.followsAppleTVUsers)
    }
}
