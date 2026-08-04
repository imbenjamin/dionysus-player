import XCTest
@testable import Dionysus

/// `ServerSessionStore` splits its two pieces of state across `UserDefaults`
/// (server config) and the Keychain (credentials) — the main thing worth
/// pinning down is that both round-trip correctly across a fresh instance
/// (i.e. really persisted, not just held in memory) and that `clearCredentials`
/// vs `clearAll` affect the right subset.
final class ServerSessionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.ServerSessionStoreTests"
    private let credentialsKey = "server.credentials" // matches ServerSessionStore.Keys.credentials

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        super.tearDown()
    }

    func test_freshStore_hasNoServerOrCredentials() {
        let store = ServerSessionStore(defaults: defaults)
        XCTAssertNil(store.serverConfiguration)
        XCTAssertNil(store.credentials)
    }

    func test_saveServer_persistsAcrossNewInstances() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        ServerSessionStore(defaults: defaults).saveServer(config)

        let reloaded = ServerSessionStore(defaults: defaults)
        XCTAssertEqual(reloaded.serverConfiguration, config)
    }

    func test_saveCredentials_persistsAcrossNewInstances() {
        let credentials = StoredCredentials(username: "ben", password: "hunter2", accessToken: "tok", userID: "user-1")
        ServerSessionStore(defaults: defaults).saveCredentials(credentials)

        let reloaded = ServerSessionStore(defaults: defaults)
        XCTAssertEqual(reloaded.credentials, credentials)
    }

    func test_clearCredentials_removesCredentialsButKeepsServer() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        let credentials = StoredCredentials(username: "ben", password: nil, accessToken: "tok", userID: "user-1")
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(config)
        store.saveCredentials(credentials)

        store.clearCredentials()

        XCTAssertNil(store.credentials)
        XCTAssertEqual(store.serverConfiguration, config)
        XCTAssertNil(ServerSessionStore(defaults: defaults).credentials, "Should also be gone from the Keychain, not just this instance")
    }

    func test_clearAll_removesBothServerAndCredentials() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        let credentials = StoredCredentials(username: "ben", password: nil, accessToken: "tok", userID: "user-1")
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(config)
        store.saveCredentials(credentials)

        store.clearAll()

        XCTAssertNil(store.serverConfiguration)
        XCTAssertNil(store.credentials)
        let reloaded = ServerSessionStore(defaults: defaults)
        XCTAssertNil(reloaded.serverConfiguration)
        XCTAssertNil(reloaded.credentials)
    }
}
