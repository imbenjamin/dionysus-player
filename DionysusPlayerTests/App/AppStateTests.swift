import XCTest
@testable import Dionysus

/// `AppState` is the top-level `.serverSetup` → `.login` → `.main` state
/// machine — previously untested. Unlike the feature ViewModels, it builds
/// its own `JellyfinAPIClient` internally (see `completeServerSetup`/
/// `start`) rather than taking one by injection, always on `URLSession
/// .shared`. `MockURLProtocol` can still intercept that: `URLProtocol
/// .registerClass` hooks the shared/default session process-wide, which is
/// exactly the scenario it exists for (confirmed against a standalone
/// executable before relying on it here — `.shared` really does route
/// through registered `URLProtocol`s).
@MainActor
final class AppStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.AppStateTests"
    private let credentialsKey = "server.credentials" // matches ServerSessionStore.Keys.credentials
    private let exampleServer = ServerConfiguration(name: "Home", baseURL: URL(string: "https://jellyfin.example.com")!)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        super.tearDown()
    }

    private func makeAppState() -> AppState {
        AppState(sessionStore: ServerSessionStore(defaults: defaults))
    }

    // MARK: start()

    func test_start_noServerConfigured_goesToServerSetup() async {
        let appState = makeAppState()
        await appState.start()
        XCTAssertEqual(appState.phase, .serverSetup)
        XCTAssertFalse(appState.isRestoringSession)
    }

    func test_start_serverConfiguredButNoCredentials_goesToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNotNil(appState.apiClient)
    }

    func test_start_validRememberedCredentials_signsInAutomatically() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: "old-token", userID: "user-1"))
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "new-token", serverId: "s1")
            )
        }
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
    }

    func test_start_rememberedCredentialsNoLongerValid_fallsBackToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "stale", accessToken: nil, userID: nil))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }
        let appState = AppState(sessionStore: store)

        await appState.start()

        // A real HTTP response (bad credentials) — not a connectivity
        // failure — must still land on `.login`, not `.offline`.
        XCTAssertEqual(appState.phase, .login)
    }

    /// Distinct from the test above: the server couldn't be reached at all
    /// (a `URLError`, not an HTTP response), so this should land on the new
    /// `.offline` phase instead of `.login` — see `Phase.offline`'s doc
    /// comment for why the two are kept separate.
    func test_start_serverUnreachable_goesToOffline() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: nil, userID: nil))
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .offline)
    }

    // MARK: completeServerSetup / signIn / signOut / changeServer

    func test_completeServerSetup_savesServerAndMovesToLogin() {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNotNil(appState.apiClient)
        XCTAssertEqual(appState.sessionStore.serverConfiguration, exampleServer)
    }

    func test_signIn_success_setsUserPhaseAndPersistsCredentials() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "tok", serverId: nil)
            )
        }

        let user = try await appState.signIn(username: "ben", password: "hunter2")

        XCTAssertEqual(user.id, "user-1")
        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.sessionStore.credentials?.accessToken, "tok")
    }

    func test_signIn_withoutConfiguredServer_throwsInvalidServerAddress() async {
        let appState = makeAppState()
        do {
            _ = try await appState.signIn(username: "ben", password: "hunter2")
            XCTFail("Expected signIn to throw without a configured server")
        } catch JellyfinAPIError.invalidServerAddress {
            // expected
        } catch {
            XCTFail("Expected .invalidServerAddress, got \(error)")
        }
    }

    func test_signOut_clearsCredentialsButKeepsServerConfigured() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "tok", serverId: nil)
            )
        }
        _ = try await appState.signIn(username: "ben", password: "hunter2")

        appState.signOut()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNil(appState.currentUser)
        XCTAssertNotNil(appState.sessionStore.serverConfiguration)
        XCTAssertNil(appState.sessionStore.credentials)
    }

    func test_changeServer_clearsServerCredentialsAndClient() {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)

        appState.changeServer()

        XCTAssertEqual(appState.phase, .serverSetup)
        XCTAssertNil(appState.apiClient)
        XCTAssertNil(appState.currentUser)
        XCTAssertNil(appState.sessionStore.serverConfiguration)
    }
}
