import XCTest
@testable import Dionysus

/// Who's Watching? on Apple TV: Quick Connect is the primary route, typing a
/// password with the remote the fallback. Only `hasPassword == false` is
/// conclusive (see `JellyfinAPIClient.publicUsers()`), so only that signs in
/// on one press.
final class TVSignInRouteTests: XCTestCase {
    private func user(hasPassword: Bool?) -> UserDto {
        UserDto(id: "u1", name: "Ben", hasPassword: hasPassword, primaryImageTag: nil)
    }

    func test_passwordlessUser_signsInNow_evenWithQuickConnect() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: false), quickConnectAvailable: true), .signInNow)
    }

    func test_passwordUser_goesToQuickConnect_whenTheServerHasIt() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: true), quickConnectAvailable: true), .quickConnect)
    }

    func test_passwordUser_goesToPassword_whenQuickConnectIsOff() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: true), quickConnectAvailable: false), .password)
    }

    /// The server didn't say: treated as needing a password, as iOS does.
    func test_unknownPasswordState_isTreatedAsHavingOne() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: nil), quickConnectAvailable: true), .quickConnect)
    }
}
