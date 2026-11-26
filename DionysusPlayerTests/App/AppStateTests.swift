import AetherEngine
import Security
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
    private let serverKey = "server.configuration" // matches ServerSessionStore.Keys.serverConfiguration
    private let exampleServer = ServerConfiguration(name: "Home", baseURL: URL(string: "https://jellyfin.example.com")!)
    /// Each test's own, so nothing reaches the app host's `.shared` (#466).
    private var trustRegistry: ServerTrustRegistry!
    private var savedDidChange: (@Sendable (ServerTrustRegistry) -> Void)?
    private var savedEvaluator: (@Sendable (URLProtectionSpace) -> Bool)?

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        trustRegistry = ServerTrustRegistry()
        savedDidChange = ServerTrustRegistry.didChange
        savedEvaluator = EngineTLS.serverTrustEvaluator
        URLProtocol.registerClass(MockURLProtocol.self)
        // Requests on `URLSession.shared` can't be stamped with a generation.
        MockURLProtocol.acceptsUnmarkedRequests = true
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        ServerTrustRegistry.didChange = savedDidChange
        EngineTLS.serverTrustEvaluator = savedEvaluator
        trustRegistry = nil
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        KeychainStore.delete(forKey: serverKey, scope: .allUsers)
        KeychainStore.delete(forKey: "server.rememberedAccounts")
        #if os(tvOS)
        SessionScopeSetting.reset()
        KeychainStore.delete(forKey: credentialsKey, scope: .allUsers)
        KeychainStore.delete(forKey: "server.rememberedAccounts", scope: .allUsers)
        #endif
        try await super.tearDown()
    }

    private func makeAppState() -> AppState {
        AppState(sessionStore: ServerSessionStore(defaults: defaults), trustRegistry: trustRegistry)
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
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

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
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
    }

    func test_start_rememberedCredentialsNoLongerValid_fallsBackToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "stale", accessToken: nil, userID: nil))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

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
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertNil(appState.currentUser)
        let restoredToken = await appState.apiClient?.accessToken
        XCTAssertEqual(restoredToken, "cached-token")
    }

    /// The resumed session has no `currentUser` yet, so the signed-in user
    /// comes from the cached credentials. tvOS's root keyed on `currentUser`
    /// alone and drew nothing at all on such a launch.
    func test_start_serverUnreachable_signedInUserIDFallsBackToCachedCredentials() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: "cached-token", userID: "user-1"))
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertNil(appState.currentUser)
        XCTAssertEqual(appState.signedInUserID, "user-1")
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
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
    }

    // MARK: start() — Quick Connect sessions

    /// No password to sign in with again, so the stored token is checked
    /// instead — and `AuthenticateByName` is never called with an empty one.
    func test_start_quickConnectSession_validatesTokenInsteadOfSigningIn() async throws {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(
            username: "ben", password: nil, accessToken: "qc-token", userID: "user-1", authMethod: .quickConnect
        ))
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: UserDto(id: "user-1", name: "ben"))
        }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
        XCTAssertEqual(paths, ["/Users/Me"])
        let token = await appState.apiClient?.accessToken
        XCTAssertEqual(token, "qc-token")
    }

    func test_start_quickConnectSessionRevoked_fallsBackToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(
            username: "ben", password: nil, accessToken: "revoked", userID: "user-1", authMethod: .quickConnect
        ))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
    }

    func test_start_quickConnectSessionServerUnreachable_resumesFromCache() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(
            username: "ben", password: nil, accessToken: "qc-token", userID: "user-1", authMethod: .quickConnect
        ))
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        let token = await appState.apiClient?.accessToken
        XCTAssertEqual(token, "qc-token")
    }

    func test_signInWithQuickConnect_savesTokenOnlyCredentials() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "qc-token", serverId: nil)
            )
        }

        try await appState.signInWithQuickConnect(secret: "abc123")

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
        XCTAssertEqual(
            appState.sessionStore.credentials,
            StoredCredentials(
                username: "ben", password: nil, accessToken: "qc-token", userID: "user-1",
                authMethod: .quickConnect, serverID: exampleServer.id
            )
        )
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
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler

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
        // The client's forget is a fire-and-forget actor hop with nothing
        // observable to wait on, so this lets it land: the test fails, not
        // flakes, if it ever hasn't (the 401 below would be retried).
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

    // MARK: Welcome

    func test_completeWelcome_marksItDoneWithoutLeavingServerSetup() {
        let appState = makeAppState()
        XCTAssertFalse(appState.sessionStore.hasCompletedWelcome)

        appState.completeWelcome()

        XCTAssertTrue(appState.sessionStore.hasCompletedWelcome)
        XCTAssertEqual(appState.phase, .serverSetup)
    }

    func test_changeServer_doesNotBringTheWelcomeBack() {
        let appState = makeAppState()
        appState.completeWelcome()
        appState.completeServerSetup(ServerConfiguration(name: "Home", baseURL: URL(string: "https://jellyfin.example.com")!))

        appState.changeServer()

        XCTAssertEqual(appState.phase, .serverSetup)
        XCTAssertTrue(appState.sessionStore.hasCompletedWelcome)
    }

    // MARK: Credentials bound to a server

    private static let authenticateByNameHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        try MockURLProtocol.encodedJSONResponse(
            for: request,
            value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "tok", serverId: nil)
        )
    }

    /// Another Apple TV user changed the shared server. This user's own
    /// credentials were issued by the old one and must not be replayed against
    /// the new one, where the same username could be someone else.
    func test_start_credentialsBoundToAnotherServer_discardsThemAndGoesToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(
            username: "ben", password: "pw", accessToken: "tok", userID: "u1",
            serverID: "https://old.example.com"
        ))
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No request may be sent with credentials from another server")
            throw URLError(.badServerResponse)
        }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNil(store.credentials)
    }

    func test_signIn_bindsCredentialsToTheConfiguredServer() async throws {
        let store = ServerSessionStore(defaults: defaults)
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler

        try await appState.signIn(username: "ben", password: "pw")

        XCTAssertEqual(store.credentials?.serverID, exampleServer.id)
    }

    // MARK: Remembered accounts (tvOS)

    private func makeRememberingAppState() -> AppState {
        AppState(sessionStore: ServerSessionStore(defaults: defaults, remembersAccounts: true), trustRegistry: trustRegistry)
    }

    func test_signInRememberedPasswordAccount_signsInWithItsStoredPassword() async throws {
        let appState = makeRememberingAppState()
        appState.completeServerSetup(exampleServer)
        // The handler runs on a URL loading thread: it only stores the bytes.
        nonisolated(unsafe) var sentData: Data?
        MockURLProtocol.requestHandler = { request in
            sentData = request.capturedHTTPBody
            return try Self.authenticateByNameHandler(request)
        }
        let remembered = StoredCredentials(username: "ben", password: "pw", accessToken: "old", userID: "user-1", serverID: exampleServer.id)

        try await appState.signIn(rememberedAccount: remembered)

        XCTAssertEqual(appState.phase, .main)
        let sentBody = String(data: sentData ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(sentBody.contains("\"Pw\":\"pw\""), sentBody)
        XCTAssertEqual(appState.sessionStore.credentials?.accessToken, "tok")
    }

    func test_signInRememberedQuickConnectAccount_validatesItsTokenInsteadOfSigningIn() async throws {
        let appState = makeRememberingAppState()
        appState.completeServerSetup(exampleServer)
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: UserDto(id: "user-1", name: "ben"))
        }
        let remembered = StoredCredentials(username: "ben", password: nil, accessToken: "qc", userID: "user-1",
                                           authMethod: .quickConnect, serverID: exampleServer.id)

        try await appState.signIn(rememberedAccount: remembered)

        XCTAssertEqual(paths, ["/Users/Me"], "A Quick Connect account has no password to send")
        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
        XCTAssertEqual(appState.sessionStore.credentials?.accessToken, "qc")
    }

    /// The password was changed elsewhere, or the token revoked: the person
    /// stays on Who's Watching?, signed in as nobody, and the account stays
    /// remembered until they forget it.
    func test_signInRememberedAccount_thatNoLongerWorks_throwsAndStaysRemembered() async {
        let appState = makeRememberingAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler
        _ = try? await appState.signIn(username: "ben", password: "pw")
        appState.signOut()
        let remembered = appState.sessionStore.rememberedAccounts(forServer: exampleServer.id)
        XCTAssertEqual(remembered.map(\.userID), ["user-1"])
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }

        do {
            try await appState.signIn(rememberedAccount: remembered[0])
            XCTFail("Expected the stale account to be refused")
        } catch {}

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNil(appState.sessionStore.credentials)
        XCTAssertNil(appState.currentUser)
        XCTAssertEqual(appState.sessionStore.rememberedAccounts(forServer: exampleServer.id).map(\.userID), ["user-1"])
    }

    /// An account remembered for another server is never replayed against
    /// this one, where the same name could be someone else.
    func test_signInRememberedAccount_fromAnotherServer_isRefusedWithoutARequest() async {
        let appState = makeRememberingAppState()
        appState.completeServerSetup(exampleServer)
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try Self.authenticateByNameHandler(request)
        }
        let foreign = StoredCredentials(username: "ben", password: "pw", accessToken: "old", userID: "user-1", serverID: "https://other.example.com")

        do {
            try await appState.signIn(rememberedAccount: foreign)
            XCTFail("Expected an account from another server to be refused")
        } catch {}

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(appState.phase, .login)
    }

    // MARK: Who's Watching? at every relaunch (tvOS, Follow Apple TV Users off)

    #if os(tvOS)
    /// A shared-session store with `accounts` remembered, the last signed in.
    private func makeSharedAppState(accounts: [String]) -> AppState {
        let store = ServerSessionStore(defaults: defaults, remembersAccounts: true, sessionScope: .allUsers)
        store.saveServer(exampleServer)
        for id in accounts {
            store.saveCredentials(StoredCredentials(username: id, password: "pw", accessToken: "tok", userID: id, serverID: exampleServer.id))
        }
        return AppState(sessionStore: store, trustRegistry: trustRegistry)
    }

    func test_start_sharedSessionWithSeveralAccounts_asksWhoIsWatching_withoutSigningIn() async {
        SessionScopeSetting.set(false)
        let appState = makeSharedAppState(accounts: ["ben", "tara"])
        nonisolated(unsafe) var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try Self.authenticateByNameHandler(request)
        }

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(appState.sessionStore.credentials, "Nobody is signed in until someone is chosen")
        XCTAssertEqual(appState.sessionStore.rememberedAccounts(forServer: exampleServer.id).count, 2)
    }

    func test_start_sharedSessionWithOneAccount_signsStraightIn() async {
        SessionScopeSetting.set(false)
        let appState = makeSharedAppState(accounts: ["ben"])
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
    }

    func test_start_selectAUserEveryRelaunchOff_signsStraightIn() async {
        SessionScopeSetting.set(false)
        SessionScopeSetting.setSelectsUserEveryRelaunch(false)
        let appState = makeSharedAppState(accounts: ["ben", "tara"])
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
    }

    func test_returningAfterHalfAnHourAway_asksWhoIsWatching_soonerDoesNot() async {
        SessionScopeSetting.set(false)
        let appState = makeSharedAppState(accounts: ["ben", "tara"])
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler
        _ = try? await appState.signIn(username: "tara", password: "pw")
        XCTAssertEqual(appState.phase, .main)
        let left = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(appState.asksWhoIsWatching(returningAt: left), "Never away")
        appState.didEnterBackground(at: left)
        XCTAssertFalse(appState.asksWhoIsWatching(returningAt: left.addingTimeInterval(29 * 60)))
        appState.didEnterBackground(at: left)
        XCTAssertTrue(appState.asksWhoIsWatching(returningAt: left.addingTimeInterval(30 * 60)))
        XCTAssertFalse(appState.asksWhoIsWatching(returningAt: left.addingTimeInterval(31 * 60)), "Asked once per time away")
    }

    func test_returningAfterHalfAnHourAway_followingAppleTVUsers_doesNotAsk() async {
        let appState = makeSharedAppState(accounts: ["ben", "tara"])
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler
        _ = try? await appState.signIn(username: "tara", password: "pw")
        XCTAssertEqual(appState.phase, .main)
        XCTAssertGreaterThan(appState.sessionStore.rememberedAccounts(forServer: exampleServer.id).count, 1)
        let left = Date(timeIntervalSince1970: 1_000_000)

        appState.didEnterBackground(at: left)
        XCTAssertFalse(appState.asksWhoIsWatching(returningAt: left.addingTimeInterval(60 * 60)))
    }
    #endif

    // MARK: Certificate warning (#466)

    private var exampleOrigin: ServerOrigin { exampleServer.origin }
    /// An address setup tried that isn't the configured server's.
    private let candidateOrigin = ServerOrigin(host: "192.168.1.20", port: 8920)

    private func trustedServer(_ trust: ServerCertificateTrust?) -> ServerConfiguration {
        var server = exampleServer
        server.certificateTrust = trust
        return server
    }

    /// A store holding `server` and a signed-in session, with `trustRegistry`
    /// configured for it as launch does.
    private func signedInStore(server: ServerConfiguration) -> ServerSessionStore {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(server)
        store.saveCredentials(StoredCredentials(username: "ben", password: "hunter2", accessToken: "cached-token", userID: "user-1"))
        trustRegistry.configure(server: server)
        return store
    }

    private func answerSignInSuccessfully() {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "new-token", serverId: "s1")
            )
        }
    }

    /// Presents the fixture `leaf` to `registry` at `origin`, as a challenge.
    nonisolated private static func present(
        _ leaf: String,
        to registry: ServerTrustRegistry,
        at origin: ServerOrigin
    ) -> ServerTrustDecision {
        registry.decide(TLSFixtures.trust(leaf: leaf, anchors: [], host: nil), host: origin.host, port: origin.port)
    }

    /// Off the main actor, as a URLSession delegate queue would.
    @discardableResult
    private func present(_ leaf: String, at origin: ServerOrigin? = nil) async -> ServerTrustDecision {
        let registry = trustRegistry!
        let origin = origin ?? exampleOrigin
        return await Task.detached { Self.present(leaf, to: registry, at: origin) }.value
    }

    /// The refusal reaches `AppState` through a hop to the main actor.
    private func waitForWarning(_ appState: AppState, file: StaticString = #filePath, line: UInt = #line) async throws -> CertificateWarning {
        for _ in 0..<200 {
            if let warning = appState.certificateWarning { return warning }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(appState.certificateWarning, "No certificate warning was raised", file: file, line: line)
    }

    /// Long enough for a hop to the main actor that would raise one.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func testRefusalOfATrustedServerRaisesTheChangedWarning() async throws {
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(pinned)), trustRegistry: trustRegistry)

        await present("selfSignedB")

        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.kind, .changed(previous: pinned))
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("selfSignedB"))
        XCTAssertEqual(warning.details.trust, .certificate(TLSFixtures.der("selfSignedB")))
        XCTAssertEqual(warning.id, warning.details.fingerprint)
    }

    func testRefusalOfAServerWithNoTrustRaisesTheUntrustedWarning() async throws {
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(nil)), trustRegistry: trustRegistry)

        await present("selfSignedB")

        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.kind, .untrusted)
        XCTAssertEqual(warning.details.kind, .selfSigned)
    }

    /// Setup's candidate refused at an address other than the configured
    /// server's (setup re-probing): the setup offer's business, never the
    /// warning's.
    func testARefusalForAnotherOriginRaisesNothing() async throws {
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(nil)), trustRegistry: trustRegistry)
        trustRegistry.setCandidate(.certificate(TLSFixtures.der("selfSignedA")), for: candidateOrigin)

        let decision = await present("selfSignedB", at: candidateOrigin)
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("selfSignedB")))
        try await settle()

        XCTAssertNil(appState.certificateWarning)
    }

    /// The same during first-run setup, before any server is saved.
    func testARefusalWithNoServerConfiguredRaisesNothing() async throws {
        let appState = makeAppState()
        trustRegistry.setCandidate(.certificate(TLSFixtures.der("selfSignedA")), for: candidateOrigin)

        let decision = await present("selfSignedB", at: candidateOrigin)
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("selfSignedB")))
        try await settle()

        XCTAssertNil(appState.certificateWarning)
    }

    func testARefusalAtLaunchShowsTheWarningInsteadOfLogin() async throws {
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        let store = signedInStore(server: trustedServer(pinned))
        let registry = trustRegistry!
        let origin = exampleOrigin
        MockURLProtocol.requestHandler = { _ in
            _ = Self.present("selfSignedB", to: registry, at: origin)
            throw URLError(.serverCertificateUntrusted)
        }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)

        await appState.start()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline)
        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.kind, .changed(previous: pinned))
        let restoredToken = await appState.apiClient?.accessToken
        XCTAssertEqual(restoredToken, "cached-token")
    }

    func testTrustingThePresentedCertificateSavesItAndRestarts() async throws {
        let store = signedInStore(server: trustedServer(.certificate(TLSFixtures.der("selfSignedA"))))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        await appState.trustPresentedCertificate()

        let trusted = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedB"))
        XCTAssertEqual(ServerSessionStore(defaults: defaults).serverConfiguration?.certificateTrust, trusted)
        XCTAssertEqual(trustRegistry.trust(for: exampleOrigin), trusted)
        XCTAssertNil(appState.certificateWarning)
        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline, "The restart's first answer marks it online again")
    }

    /// The restart signs in again on the client the app already has. The
    /// signed-in views keep the client they were built with, so a new one
    /// left them on a token the sign-in revokes (one per device id), and
    /// their re-authentication then revoked the token just saved, which the
    /// Top Shelf presents (seen on the Apple TV Simulator, 2026-11-25).
    func testTrustingKeepsTheSameClientAndItsNewToken() async throws {
        let store = signedInStore(server: trustedServer(.certificate(TLSFixtures.der("selfSignedA"))))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        let client = try XCTUnwrap(appState.apiClient)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        await appState.trustPresentedCertificate()

        XCTAssertTrue(appState.apiClient === client, "The views' client is the one signed in again")
        let token = await client.accessToken
        XCTAssertNotNil(token)
        XCTAssertEqual(token, store.credentials?.accessToken, "The client holds the token that was saved and mirrored")
    }

    /// A refusal decided under a trust since replaced (its details are read
    /// off the main actor, so it can land after Trust) raises nothing and is
    /// handed back: the same leaf refused under the trust now held raises the
    /// warning against that trust.
    func testARefusalDecidedUnderAReplacedTrustIsDroppedAndHandedBack() async throws {
        let trustA = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        let trustB = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedB"))
        let store = signedInStore(server: trustedServer(trustA))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()

        // nameLeaf refused under A, held back from AppState as a slow hop would be.
        let hook = trustRegistry.onRefusal
        let captured = StaleRefusalBox()
        trustRegistry.onRefusal = { captured.refusal = $0 }
        await present("nameLeaf")
        trustRegistry.onRefusal = hook
        let stale = try XCTUnwrap(captured.refusal)
        XCTAssertEqual(stale.previous, trustA)

        // B is trusted meanwhile.
        await present("selfSignedB")
        _ = try await waitForWarning(appState)
        await appState.trustPresentedCertificate()
        XCTAssertEqual(store.serverConfiguration?.certificateTrust, trustB)

        // The stale refusal lands now: nothing is raised.
        trustRegistry.onRefusal?(stale)
        try await settle()
        XCTAssertNil(appState.certificateWarning, "a refusal decided under A says nothing once B is trusted")

        // Handed back: the same leaf, refused under B, is reported and raised.
        await present("nameLeaf")
        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("nameLeaf"))
        XCTAssertEqual(warning.kind, .changed(previous: trustB))
    }

    /// Trust's restart reuses the client. When its sign-in is refused (a
    /// password changed on the server), the app lands on the login screen
    /// and the client must not keep the old credentials to sign back in
    /// with, as after `signOut()`.
    func testATrustRestartThatLandsOnLoginForgetsTheReauthCredentials() async throws {
        let store = signedInStore(server: trustedServer(.certificate(TLSFixtures.der("selfSignedA"))))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        let client = try XCTUnwrap(appState.apiClient)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        let signIns = TrustRestartSignIns()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/Users/AuthenticateByName") == true { signIns.increment() }
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        await appState.trustPresentedCertificate()
        XCTAssertEqual(appState.phase, .login)
        XCTAssertEqual(signIns.value, 1, "the restart's sign-in, refused")

        // A straggler from the torn-down views, carrying the old token.
        do {
            _ = try await client.userViews(userID: "user-1")
            XCTFail("the old session's request should fail")
        } catch {}
        XCTAssertEqual(signIns.value, 1, "no re-authentication as the previous user on the login screen")
    }

    /// Trust marks the app offline before restarting, so whatever failed under
    /// the refusal reloads when the restart's answer marks it online.
    func testTrustingMarksOfflineUntilTheRestartIsAnswered() async throws {
        let store = signedInStore(server: trustedServer(nil))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)
        let answered = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            _ = answered.wait(timeout: .now() + 5)
            return try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "new-token", serverId: "s1")
            )
        }

        let trusting = Task { await appState.trustPresentedCertificate() }
        for _ in 0..<200 where !ConnectivityMonitor.shared.isOffline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline, "Offline while the restart waits for its answer")
        answered.signal()
        await trusting.value

        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
        XCTAssertEqual(appState.phase, .main)
    }

    #if os(tvOS)
    /// Trust restarts the session in place: never Who's Watching?, which only
    /// a launch asks.
    func testTrustingOnTheAppleTVDoesNotAskWhoIsWatching() async throws {
        SessionScopeSetting.set(false)
        SessionScopeSetting.setSelectsUserEveryRelaunch(true)
        let appState = makeSharedAppState(accounts: ["ben", "tara"])
        appState.completeServerSetup(exampleServer)
        answerSignInSuccessfully()
        try await appState.signIn(username: "ben", password: "pw")
        XCTAssertEqual(appState.phase, .main)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        await appState.trustPresentedCertificate()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertNotNil(appState.sessionStore.credentials)
    }
    #endif

    func testStayOfflineForNowResumesOfflineWithDownloads() async throws {
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        let store = signedInStore(server: trustedServer(pinned))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        appState.stayOfflineForNow()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline)
        XCTAssertNil(appState.certificateWarning)
        XCTAssertEqual(store.serverConfiguration?.certificateTrust, pinned, "Not Now trusts nothing")
    }

    func testStayOfflineForNowWithoutASessionStaysOnLogin() async throws {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(trustedServer(nil))
        trustRegistry.configure(server: store.serverConfiguration)
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        appState.stayOfflineForNow()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNil(appState.certificateWarning)
    }

    /// Not Now while the launch is still signing in: the cached session
    /// resumes at once, offline.
    func testNotNowDuringTheLaunchResumesTheCachedSession() async throws {
        let store = signedInStore(server: trustedServer(nil))
        let registry = trustRegistry!
        let origin = exampleOrigin
        let answered = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { _ in
            _ = Self.present("selfSignedB", to: registry, at: origin)
            _ = answered.wait(timeout: .now() + 5)
            throw URLError(.serverCertificateUntrusted)
        }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        let launch = Task { await appState.start() }
        _ = try await waitForWarning(appState)
        XCTAssertTrue(appState.isRestoringSession)

        appState.stayOfflineForNow()

        XCTAssertEqual(appState.phase, .main)
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline)
        XCTAssertNil(appState.certificateWarning)
        answered.signal()
        await launch.value
        XCTAssertEqual(appState.phase, .main)
    }

    /// On the login screen, whose stored session the server refused (a 401),
    /// Not Now never resumes it.
    func testNotNowOnTheLoginScreenStaysThere() async throws {
        let store = signedInStore(server: trustedServer(nil))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        XCTAssertEqual(appState.phase, .login)
        XCTAssertNotNil(store.credentials?.accessToken)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        appState.stayOfflineForNow()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
        XCTAssertNil(appState.certificateWarning)
    }

    /// A certificate refused while another warning is up raises nothing then,
    /// but isn't silenced for the launch: its next refusal, once that warning
    /// is answered, raises it.
    func testACertificateRefusedWhileAWarningIsUpIsRaisedLater() async throws {
        let store = signedInStore(server: trustedServer(nil))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        await present("selfSignedA")
        try await settle()
        XCTAssertEqual(appState.certificateWarning?.details.leaf, TLSFixtures.der("selfSignedB"))

        await appState.trustPresentedCertificate()
        XCTAssertNil(appState.certificateWarning)
        await present("selfSignedA")

        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("selfSignedA"))
        XCTAssertEqual(warning.kind, .changed(previous: .certificate(TLSFixtures.der("selfSignedB"))))
    }

    /// With no session for the restart to sign in, nothing would mark the app
    /// online again, so Trust doesn't mark it offline.
    func testTrustingWithoutASessionLeavesTheAppOnline() async throws {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(trustedServer(nil))
        trustRegistry.configure(server: store.serverConfiguration)
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        await appState.trustPresentedCertificate()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertFalse(ConnectivityMonitor.shared.isOffline)
        XCTAssertEqual(store.serverConfiguration?.certificateTrust, .certificate(TLSFixtures.der("selfSignedB")))
    }

    func testTheSameCertificateDoesNotRaiseTheWarningAgainAfterNotNow() async throws {
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(nil)), trustRegistry: trustRegistry)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)
        appState.stayOfflineForNow()

        await present("selfSignedB")
        try await settle()

        XCTAssertNil(appState.certificateWarning)
    }

    /// The presenter gave up showing it: offline as after Not Now, but the
    /// same certificate's next refusal raises the warning again.
    func testWithdrawingAnUnshownWarningGoesOfflineAndAsksAgain() async throws {
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        answerSignInSuccessfully()
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(pinned)), trustRegistry: trustRegistry)
        await appState.start()
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        appState.withdrawUnshownCertificateWarning()

        XCTAssertNil(appState.certificateWarning)
        XCTAssertTrue(ConnectivityMonitor.shared.isOffline, "Carries on offline, as Not Now does")

        await present("selfSignedB")
        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("selfSignedB"), "Asked again: nothing was answered")
    }

    func testADifferentCertificateRaisesItAgain() async throws {
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(nil)), trustRegistry: trustRegistry)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)
        appState.stayOfflineForNow()

        await present("selfSignedA")

        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("selfSignedA"))
    }

    func testChangeServerClearsTheWarningAndTheRegistry() async throws {
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        let appState = AppState(sessionStore: signedInStore(server: trustedServer(pinned)), trustRegistry: trustRegistry)
        trustRegistry.setCandidate(pinned, for: candidateOrigin)
        await present("selfSignedB")
        _ = try await waitForWarning(appState)

        appState.changeServer()

        XCTAssertNil(appState.certificateWarning)
        XCTAssertEqual(appState.phase, .serverSetup)
        XCTAssertNil(trustRegistry.trust(for: exampleOrigin))
        XCTAssertNil(trustRegistry.trust(for: candidateOrigin))
        XCTAssertFalse(trustRegistry.hasStoredTrust)
    }

    // MARK: Classifying from the presented chain

    /// The headline #466 case: a CA-issued certificate for a domain name,
    /// served at a LAN address, with its issuer in the chain the server sent.
    private let lanServer = ServerConfiguration(name: "Media", baseURL: URL(string: "https://192.168.1.50")!)

    /// `nameLeaf` and `testCA` as the server sends them, with `testCA`
    /// anchored and the verify date pinned inside the leaf's window
    /// (`ServerTrustPolicyTests.nameLeafVerifyDate`).
    nonisolated private static func presentNameChain(to registry: ServerTrustRegistry, at origin: ServerOrigin) -> ServerTrustDecision {
        var trust: SecTrust?
        let certificates = [TLSFixtures.certificate("nameLeaf"), TLSFixtures.certificate("testCA")]
        SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, nil), &trust)
        let presented = trust!
        anchorTestCA(presented)
        return registry.decide(presented, host: origin.host, port: origin.port)
    }

    nonisolated private static func anchorTestCA(_ trust: SecTrust) {
        SecTrustSetAnchorCertificates(trust, [TLSFixtures.certificate("testCA")] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, ServerTrustPolicyTests.nameLeafVerifyDate as CFDate)
    }

    private final class RefusalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ServerTrustRefusal?
        var refusal: ServerTrustRefusal? { lock.withLock { stored } }
        func record(_ refusal: ServerTrustRefusal) { lock.withLock { stored = refusal } }
    }

    func testARefusalCarriesThePresentedChain() async throws {
        let registry = ServerTrustRegistry()
        registry.configure(server: lanServer)
        let box = RefusalBox()
        registry.onRefusal = { box.record($0) }
        let origin = lanServer.origin

        let decision = await Task.detached { Self.presentNameChain(to: registry, at: origin) }.value

        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("nameLeaf")))
        let refusal = try XCTUnwrap(box.refusal)
        XCTAssertEqual(refusal.presentedLeaf, TLSFixtures.der("nameLeaf"))
        XCTAssertEqual(Array(refusal.presentedChain.prefix(2)), [TLSFixtures.der("nameLeaf"), TLSFixtures.der("testCA")])
    }

    /// Classified from the refusal's chain, with `testCA` anchored through
    /// `adjustingTrust` (a public CA needs no anchoring in the app): trusted
    /// by name, with the issuer shown. From the leaf alone it was pinned.
    func testTheChainClassifiesACAIssuedCertificateByName() async throws {
        let registry = ServerTrustRegistry()
        registry.configure(server: lanServer)
        let box = RefusalBox()
        registry.onRefusal = { box.record($0) }
        let origin = lanServer.origin
        _ = await Task.detached { Self.presentNameChain(to: registry, at: origin) }.value
        let chain = try XCTUnwrap(box.refusal).presentedChain

        let classified = await Task.detached {
            ServerCertificateDetails(chain: chain, adjustingTrust: Self.anchorTestCA)
        }.value
        let details = try XCTUnwrap(classified)

        XCTAssertEqual(details.kind, .nameMismatch(validFor: ["media.dionysus.test", "*.wild.dionysus.test"]))
        XCTAssertEqual(details.trust, .names(["media.dionysus.test", "*.wild.dionysus.test"]))
        XCTAssertEqual(details.issuer, "Dionysus Test CA")
    }

    /// The app's own path, end to end: the warning's details come from the
    /// chain, so the issuer the server sent is shown. Under the system's
    /// anchors a private CA is still an untrusted issuer, as it should be.
    func testTheWarningIsClassifiedFromThePresentedChain() async throws {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(lanServer)
        trustRegistry.configure(server: lanServer)
        let appState = AppState(sessionStore: store, trustRegistry: trustRegistry)
        let registry = trustRegistry!
        let origin = lanServer.origin

        _ = await Task.detached { Self.presentNameChain(to: registry, at: origin) }.value

        let warning = try await waitForWarning(appState)
        XCTAssertEqual(warning.kind, .untrusted)
        XCTAssertEqual(warning.details.leaf, TLSFixtures.der("nameLeaf"))
        XCTAssertEqual(warning.details.issuer, "Dionysus Test CA")
        XCTAssertEqual(warning.details.kind, .untrustedIssuer)
    }

    func testCompletingSetupConfiguresTheRegistryAndEngineBridge() {
        ServerTrustRegistry.didChange = { ServerTrustEngineBridge.apply(registry: $0) }
        EngineTLS.serverTrustEvaluator = nil
        let appState = makeAppState()
        let pinned = ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA"))
        // Setup's candidate for the server being saved, and one left from
        // another address it tried.
        trustRegistry.setCandidate(pinned, for: exampleOrigin)
        trustRegistry.setCandidate(pinned, for: candidateOrigin)
        EngineTLS.serverTrustEvaluator = nil

        appState.completeServerSetup(trustedServer(pinned))

        XCTAssertEqual(trustRegistry.trust(for: exampleOrigin), pinned)
        XCTAssertNil(trustRegistry.trust(for: candidateOrigin), "setup's candidates are cleared once the server is saved")
        XCTAssertNotNil(EngineTLS.serverTrustEvaluator)
        XCTAssertEqual(appState.phase, .login)
    }
}

/// A refusal kept back from `AppState`, as a slow main-actor hop would.
private final class StaleRefusalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServerTrustRefusal?
    var refusal: ServerTrustRefusal? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Sign-in requests the mock saw, from any thread.
private final class TrustRestartSignIns: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
