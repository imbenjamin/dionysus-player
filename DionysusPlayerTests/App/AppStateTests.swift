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

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        try await super.tearDown()
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
        // failure — must still land on `.login`, not resume a session.
        XCTAssertEqual(appState.phase, .login)
    }

    /// Distinct from the test above: the server couldn't be reached at all
    /// (a `URLError`, not an HTTP response). Rather than stalling on a
    /// separate offline phase, this resumes the last known session from
    /// cache and lands straight on `.main` — `HomeView`/`SearchView`/etc.
    /// fall back to `sessionStore.credentials?.userID` when `currentUser`
    /// is still `nil`, so the tab bar and its screens work immediately
    /// using the resumed session (see `AppState.start()`'s doc comment).
    func test_start_serverUnreachable_resumesMainFromCachedSession() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: "cached-token", userID: "user-1"))
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertNil(appState.currentUser)
        let restoredToken = await appState.apiClient?.accessToken
        XCTAssertEqual(restoredToken, "cached-token")
    }

    /// Defensive fallback: a connectivity failure with remembered
    /// credentials that never actually carry a cached token/userID (not
    /// reachable in practice — `saveCredentials` is only ever called with
    /// both populated, from a prior successful sign-in — but nothing to
    /// resume a session from if it somehow happened) still falls back to
    /// `.login` rather than presenting a broken `.main`.
    func test_start_serverUnreachableNoCachedToken_fallsBackToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: nil, userID: nil))
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
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

    /// `signOut()` also forgets whatever credentials the (reused)
    /// `apiClient` remembered for 401 auto-retry — see `JellyfinAPIClient
    /// .forgetReauthCredentials()`'s doc comment for why: otherwise a
    /// request still in flight around sign-out could silently
    /// re-authenticate as the just-signed-out user. That call is
    /// fire-and-forget from `signOut()`'s side, so this gives it a moment
    /// to land before checking.
    func test_signOut_forgetsReauthCredentialsOnTheReusedClient() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "tok", serverId: nil)
            )
        }
        _ = try await appState.signIn(username: "ben", password: "hunter2")
        let client = try XCTUnwrap(appState.apiClient)

        appState.signOut()
        try await Task.sleep(for: .milliseconds(50))

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        do {
            _ = try await client.userViews(userID: "user-1")
            XCTFail("Expected .notAuthenticated")
        } catch JellyfinAPIError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }
        XCTAssertEqual(requestCount, 1, "no reauth credentials should remain after sign-out, so this shouldn't retry")
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
