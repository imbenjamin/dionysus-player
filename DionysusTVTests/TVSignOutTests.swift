import XCTest
@testable import Dionysus

/// Sign Out forgets the account on this Apple TV; Switch User keeps it
/// remembered (Benjamin, 2026-10-01).
@MainActor
final class TVSignOutTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVSignOutTests"
    private var defaults: UserDefaults!
    private let server = ServerConfiguration(name: "Home", baseURL: URL(string: "http://h")!)

    override func setUp() async throws {
        try await super.setUp()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        // The keychain isn't isolated by the defaults suite (see AppStateTests).
        KeychainStore.delete(forKey: "server.credentials")
        KeychainStore.delete(forKey: "server.configuration", scope: .allUsers)
        KeychainStore.delete(forKey: "server.rememberedAccounts")
        SessionScopeSetting.reset()
        KeychainStore.delete(forKey: "server.credentials", scope: .allUsers)
        KeychainStore.delete(forKey: "server.rememberedAccounts", scope: .allUsers)
        try await super.tearDown()
    }

    /// Ana signed in first, then Ben, who is the one signed in now.
    private func signedIn() -> (AppState, ServerSessionStore) {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(server)
        store.saveCredentials(StoredCredentials(username: "ana", password: "pw", accessToken: "t1", userID: "u-ana", serverID: server.id))
        store.saveCredentials(StoredCredentials(username: "ben", password: "pw", accessToken: "t2", userID: "u-ben", serverID: server.id))
        return (AppState(sessionStore: store), store)
    }

    func test_switchUser_keepsTheAccountRemembered() {
        let (appState, store) = signedIn()
        appState.signOut()
        XCTAssertEqual(Set(store.rememberedAccounts(forServer: server.id).compactMap(\.userID)), ["u-ana", "u-ben"])
        XCTAssertNil(store.credentials)
    }

    func test_signOut_forgetsOnlyTheAccountInUse() {
        let (appState, store) = signedIn()
        appState.signOutForgettingAccount()
        XCTAssertEqual(store.rememberedAccounts(forServer: server.id).compactMap(\.userID), ["u-ana"], "The other remembered account stays")
        XCTAssertNil(store.credentials)
        XCTAssertEqual(appState.phase, .login)
    }

    func test_signOut_withNobodySignedIn_changesNothing() {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(server)
        store.saveCredentials(StoredCredentials(username: "ana", password: "pw", accessToken: "t1", userID: "u-ana", serverID: server.id))
        store.clearCredentials()
        let appState = AppState(sessionStore: store)
        appState.signOutForgettingAccount()
        XCTAssertNil(store.credentials)
        XCTAssertEqual(store.rememberedAccounts(forServer: server.id).compactMap(\.userID), ["u-ana"])
    }
}
