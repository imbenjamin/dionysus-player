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
    private let serverKey = "server.configuration" // matches ServerSessionStore.Keys.serverConfiguration

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        KeychainStore.delete(forKey: serverKey, scope: .allUsers)
        super.tearDown()
    }

    func test_freshStore_hasNoServerOrCredentials() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        XCTAssertNil(store.serverConfiguration)
        XCTAssertNil(store.credentials)
    }

    func test_saveServer_persistsAcrossNewInstances() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).saveServer(config)

        let reloaded = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        XCTAssertEqual(reloaded.serverConfiguration, config)
    }

    func test_saveCredentials_persistsAcrossNewInstances() {
        let credentials = StoredCredentials(username: "ben", password: "hunter2", accessToken: "tok", userID: "user-1")
        ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).saveCredentials(credentials)

        let reloaded = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        XCTAssertEqual(reloaded.credentials, credentials)
    }

    func test_saveCredentials_quickConnectMethodPersists() {
        let credentials = StoredCredentials(
            username: "ben", password: nil, accessToken: "tok", userID: "user-1", authMethod: .quickConnect
        )
        ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).saveCredentials(credentials)

        XCTAssertEqual(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).credentials?.authMethod, .quickConnect)
    }

    /// Every install before Quick Connect saved credentials without an
    /// `authMethod`; they must keep signing in by password, not fail to
    /// decode (which would sign everyone out on update).
    func test_credentialsSavedBeforeQuickConnect_decodeAsPassword() throws {
        let legacy = Data(#"{"username":"ben","password":"hunter2","accessToken":"tok","userID":"user-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: legacy)

        XCTAssertEqual(decoded.authMethod, .password)
        XCTAssertEqual(decoded.password, "hunter2")
    }

    func test_clearCredentials_removesCredentialsButKeepsServer() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        let credentials = StoredCredentials(username: "ben", password: nil, accessToken: "tok", userID: "user-1")
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        store.saveServer(config)
        store.saveCredentials(credentials)

        store.clearCredentials()

        XCTAssertNil(store.credentials)
        XCTAssertEqual(store.serverConfiguration, config)
        XCTAssertNil(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).credentials, "Should also be gone from the Keychain, not just this instance")
    }

    func test_clearAll_removesBothServerAndCredentials() {
        let config = ServerConfiguration(name: "Home Server", baseURL: URL(string: "https://jellyfin.example.com")!)
        let credentials = StoredCredentials(username: "ben", password: nil, accessToken: "tok", userID: "user-1")
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        store.saveServer(config)
        store.saveCredentials(credentials)

        store.clearAll()

        XCTAssertNil(store.serverConfiguration)
        XCTAssertNil(store.credentials)
        let reloaded = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        XCTAssertNil(reloaded.serverConfiguration)
        XCTAssertNil(reloaded.credentials)
    }

    // MARK: Welcome

    func test_welcome_startsIncompleteAndPersistsOnceCompleted() {
        XCTAssertFalse(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).hasCompletedWelcome)

        ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).markWelcomeCompleted()

        XCTAssertTrue(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).hasCompletedWelcome)
    }

    /// Someone who set the app up before the welcome existed has a server but
    /// never tapped "Get Started" — and mustn't meet the first-run welcome the
    /// next time they change server.
    func test_welcome_countsAsCompletedForAnExistingServerConfiguration() {
        let config = ServerConfiguration(name: "Home", baseURL: URL(string: "https://jellyfin.example.com")!)
        let data = try! JSONEncoder().encode(config)
        defaults.set(data, forKey: "server.configuration")

        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        XCTAssertTrue(store.hasCompletedWelcome)

        store.clearAll()
        XCTAssertTrue(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).hasCompletedWelcome)
    }

    /// Changing server or signing out shouldn't replay the introduction.
    func test_clearAll_keepsTheWelcomeCompleted() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
        store.markWelcomeCompleted()

        store.clearAll()

        XCTAssertTrue(store.hasCompletedWelcome)
        XCTAssertTrue(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults).hasCompletedWelcome)
    }

    // MARK: Shared-keychain server (tvOS)

    func test_sharedKeychainServer_persistsAcrossInstances_withoutTouchingDefaults() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).saveServer(config)

        XCTAssertEqual(ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).serverConfiguration, config)
        XCTAssertNil(defaults.data(forKey: serverKey), "The shared server must not also land in one user's defaults")
    }

    /// A second Apple TV user has their own, empty `UserDefaults` but reads the
    /// same shared keychain: they see the household's server and skip the
    /// Welcome, landing on Who's Watching.
    func test_sharedKeychainServer_secondUsersFreshDefaults_seeServerAndSkipWelcome() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).saveServer(config)

        let otherSuite = "\(suiteName).otherUser"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        otherDefaults.removePersistentDomain(forName: otherSuite)
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }

        let secondUser = ServerSessionStore(defaults: otherDefaults, serverLocation: .sharedKeychain)
        XCTAssertEqual(secondUser.serverConfiguration, config)
        XCTAssertTrue(secondUser.hasCompletedWelcome)
    }

    func test_sharedKeychainServer_clearAllRemovesIt() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        let store = ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain)
        store.saveServer(config)
        store.clearAll()

        XCTAssertNil(ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).serverConfiguration)
    }

    /// Every keychain entry written before credentials were bound to a server.
    func test_credentialsSavedBeforeServerBinding_decodeWithNilServerID() throws {
        let legacy = #"{"username":"ben","password":"pw","accessToken":"tok","userID":"u1","authMethod":"password"}"#
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.serverID)
        XCTAssertEqual(decoded.username, "ben")
    }
}
