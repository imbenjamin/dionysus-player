import XCTest
@testable import Dionysus

/// Who's Watching? lists the accounts already signed in on this Apple TV
/// first, most recent first, then everyone else the server lists.
final class TVWhosWatchingLayoutTests: XCTestCase {
    private func listed(_ id: String, tag: String? = nil) -> UserDto {
        UserDto(id: id, name: id.capitalized, hasPassword: true, primaryImageTag: tag)
    }

    private func account(_ id: String, username: String? = nil) -> StoredCredentials {
        StoredCredentials(username: username ?? id, password: "", accessToken: "tok", userID: id, serverID: "s")
    }

    func test_rememberedAccountsComeFirst_inTheirOwnOrder_thenTheRest() {
        let lockups = TVWhosWatchingLayout.lockups(
            remembered: [account("tara"), account("ben")],
            listed: [listed("ben"), listed("sam"), listed("tara")]
        )
        XCTAssertEqual(lockups.map(\.user.id), ["tara", "ben", "sam"])
        XCTAssertEqual(lockups.map { $0.account != nil }, [true, true, false])
    }

    /// The server's own entry carries the avatar, so it's the one shown.
    func test_rememberedAccount_isShownByTheServersListing() {
        let lockups = TVWhosWatchingLayout.lockups(remembered: [account("ben")], listed: [listed("ben", tag: "abc")])
        XCTAssertEqual(lockups.count, 1)
        XCTAssertEqual(lockups[0].user.primaryImageTag, "abc")
    }

    /// A user hidden from the server's login screen, or a server that can't
    /// be asked: the stored username stands in.
    func test_rememberedAccount_theServerDoesNotList_isShownByItsStoredName() {
        let lockups = TVWhosWatchingLayout.lockups(remembered: [account("u9", username: "Hidden")], listed: [])
        XCTAssertEqual(lockups.map(\.user.name), ["Hidden"])
        XCTAssertNotNil(lockups[0].account)
    }

    func test_noRememberedAccounts_isTheServersList() {
        let lockups = TVWhosWatchingLayout.lockups(remembered: [], listed: [listed("ben"), listed("sam")])
        XCTAssertEqual(lockups.map(\.user.id), ["ben", "sam"])
        XCTAssertTrue(lockups.allSatisfy { $0.account == nil })
    }

    /// Five lockups to a row, "Other" included (Benjamin, 2026-10-01): four
    /// users and Other sit centred, a fifth user makes the row scroll.
    func test_rowScrolls_aboveFiveLockupsCountingOther() {
        XCTAssertFalse(TVWhosWatchingLayout.scrolls(users: 0))
        XCTAssertFalse(TVWhosWatchingLayout.scrolls(users: 4))
        XCTAssertTrue(TVWhosWatchingLayout.scrolls(users: 5))
        XCTAssertTrue(TVWhosWatchingLayout.scrolls(users: 12))
    }
}
