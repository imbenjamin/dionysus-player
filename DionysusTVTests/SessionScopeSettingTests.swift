import XCTest
@testable import Dionysus

/// The setting is one value for the whole Apple TV, stored where every Apple
/// TV user reads it, and on by default.
final class SessionScopeSettingTests: XCTestCase {
    override func tearDown() {
        SessionScopeSetting.reset()
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

    func test_selectAUserEveryRelaunch_isOnByDefault_andPersistsShared() {
        XCTAssertTrue(SessionScopeSetting.selectsUserEveryRelaunch)
        SessionScopeSetting.setSelectsUserEveryRelaunch(false)
        XCTAssertFalse(SessionScopeSetting.selectsUserEveryRelaunch)
        XCTAssertNotNil(KeychainStore.load(forKey: "settings.selectsUserEveryRelaunch", scope: .allUsers))
    }

    func test_reset_putsBothSettingsBack() {
        SessionScopeSetting.set(false)
        SessionScopeSetting.setSelectsUserEveryRelaunch(false)
        SessionScopeSetting.reset()
        XCTAssertTrue(SessionScopeSetting.followsAppleTVUsers)
        XCTAssertTrue(SessionScopeSetting.selectsUserEveryRelaunch)
    }

    /// Who's Watching? is asked only with sharing on, the setting on, and a
    /// choice to make: one remembered account signs straight in (Benjamin,
    /// 2026-10-01), and none has nobody to restore anyway.
    func test_whoIsWatchingIsAsked_onlyWhenSharing_withTheSettingOn_andAChoiceToMake() {
        func asks(_ follows: Bool, _ selects: Bool, _ accounts: Int) -> Bool {
            WhoIsWatchingPolicy.asks(followsAppleTVUsers: follows, selectsUserEveryRelaunch: selects, rememberedAccounts: accounts)
        }
        XCTAssertTrue(asks(false, true, 2))
        XCTAssertTrue(asks(false, true, 5))
        XCTAssertFalse(asks(false, true, 1))
        XCTAssertFalse(asks(false, false, 2))
        XCTAssertFalse(asks(true, true, 2))
    }

    func test_timeAway_asksFromHalfAnHour() {
        XCTAssertFalse(WhoIsWatchingPolicy.asks(afterSecondsAway: 29 * 60))
        XCTAssertTrue(WhoIsWatchingPolicy.asks(afterSecondsAway: 30 * 60))
    }
}
