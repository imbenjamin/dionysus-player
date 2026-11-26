import Foundation
import Observation

/// Root app state machine: first-run server setup, then sign-in, then the
/// main app. Also owns the `JellyfinAPIClient` instance, since it depends on
/// which server is configured.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case serverSetup
        case login
        case main
    }

    private(set) var phase: Phase = .serverSetup
    private(set) var isRestoringSession = true
    private(set) var currentUser: UserDto?
    private(set) var apiClient: JellyfinAPIClient?
    /// The configured server's certificate was refused (#466): changed since
    /// it was trusted, or failing with no trust stored. `RootView` /
    /// `TVRootView` present it over everything until it's answered.
    private(set) var certificateWarning: CertificateWarning?

    /// The signed-in user, falling back to the cached credentials while a
    /// session resumed from cache has no `currentUser` yet (see `start()`).
    var signedInUserID: String? {
        currentUser?.id ?? sessionStore.credentials?.userID
    }

    let sessionStore: ServerSessionStore
    /// `.shared` in the app; a test's own in tests.
    private let trustRegistry: ServerTrustRegistry
    #if os(tvOS)
    /// When the app last left the foreground (`asksWhoIsWatching(returningAt:)`).
    private var backgroundedAt: Date?
    #endif
    #if DOWNLOADS
    /// Offline downloads are local-device storage, not tied to which
    /// server is configured — unlike `apiClient`, this is created once
    /// here and never recreated on sign-out/change-server, so an in-flight
    /// download survives a session change untouched.
    let downloadManager: DownloadManager

    init(
        sessionStore: ServerSessionStore = ServerSessionStore(),
        downloadManager: DownloadManager = DownloadManager(),
        trustRegistry: ServerTrustRegistry = .shared
    ) {
        self.sessionStore = sessionStore
        self.downloadManager = downloadManager
        self.trustRegistry = trustRegistry
        // See `DownloadManager.onRowMarkedForDeletion`'s doc comment
        // for the bug this fixes and why it's wired here (the one place
        // that can resolve a *live* `apiClient`, read fresh through `self`
        // each time this actually fires rather than captured once — it can
        // be recreated or go `nil` across sign-in/sign-out/server changes
        // over this same long-lived `downloadManager`'s lifetime).
        downloadManager.onRowMarkedForDeletion = { [weak self] in
            guard let self, let client = self.apiClient else { return }
            Task { await DownloadSyncManager.syncIfNeeded(client: client, store: self.downloadManager.store) }
        }
        observeRefusals()
    }
    #else
    init(sessionStore: ServerSessionStore = ServerSessionStore(), trustRegistry: ServerTrustRegistry = .shared) {
        self.sessionStore = sessionStore
        self.trustRegistry = trustRegistry
        observeRefusals()
    }
    #endif

    /// Call once at launch: restores the configured server and attempts to
    /// sign the user back in with their remembered credentials. If the
    /// server can't be reached at all, resumes the last known session from
    /// cache instead of stalling — see the `catch` block below.
    ///
    /// `isRelaunch: false` restarts the session in place (the certificate
    /// warning's Trust), skipping what only a launch does: the Apple TV's
    /// Who's Watching? question.
    func start(isRelaunch: Bool = true) async {
        defer { isRestoringSession = false }

        // Fire-and-forget, not awaited: pays CoreMotion's one-time
        // daemon-connection bootstrap cost during the splash/session-restore
        // window instead of whenever the user first reaches the "3D Depth
        // Effects" toggle or a detail page — see
        // `DeviceTiltObserver.warmUp()`'s doc comment. Must never delay
        // showing the actual app once sign-in restore finishes.
        #if os(iOS)
        Task { await DeviceTiltObserver.shared.warmUp() }
        #endif

        // Launch already loaded it (`loadFromStore`); this keeps it right
        // after a restart from the warning, or another Apple TV user's change.
        trustRegistry.configure(server: sessionStore.serverConfiguration)

        guard let server = sessionStore.serverConfiguration else {
            phase = .serverSetup
            return
        }

        // A restart from the certificate warning (#466) is on the same server:
        // it signs in again on the client the signed-in views were built
        // with. A new client left them on a token the sign-in revokes (one
        // per device id), and their re-authentication then revoked the token
        // just saved, which the Top Shelf presents.
        let client: JellyfinAPIClient
        if !isRelaunch, let current = apiClient, await current.baseURL == server.baseURL {
            client = current
        } else {
            client = JellyfinAPIClient(baseURL: server.baseURL)
            apiClient = client
        }

        guard let credentials = sessionStore.credentials else {
            phase = .login
            return
        }

        // Another Apple TV user changed the shared server since these were
        // saved (see `StoredCredentials.serverID`).
        if let boundServerID = credentials.serverID, boundServerID != server.id {
            sessionStore.clearCredentials()
            phase = .login
            return
        }

        // One session shared by every Apple TV user: each launch asks who it
        // is (`WhoIsWatchingPolicy`). Signed out as Switch User does, so the
        // accounts stay remembered and one press signs one in.
        #if os(tvOS)
        if isRelaunch, asksWhoIsWatching {
            sessionStore.clearCredentials()
            phase = .login
            return
        }
        #endif

        do {
            switch credentials.authMethod {
            case .password:
                try await signIn(username: credentials.username, password: credentials.password ?? "", client: client)
            case .quickConnect:
                try await resumeQuickConnectSession(credentials, client: client)
            }
        } catch {
            // `ConnectivityMonitor` reflects this specific attempt's outcome
            // since `sendRaw`'s reporting call is awaited inline in the same
            // chain this catch waits on, so it's never stale here. A 401/other
            // HTTP error still reports success, so bad credentials still land
            // on `.login` as before (the remembered credentials no longer
            // work — fall back to manual sign-in).
            //
            // A connectivity failure instead resumes the last known session
            // from cache rather than stalling on a separate offline phase —
            // `credentials.accessToken`/`.userID` are always populated here,
            // since `saveCredentials` is only ever called from the success
            // paths of `signIn()` and `signInWithQuickConnect` below. A Quick
            // Connect session restores with no password, so once connectivity
            // returns a 401 has nothing to re-authenticate with and surfaces
            // as `.notAuthenticated`. `currentUser` stays `nil`
            // until a real sign-in eventually succeeds; everywhere that
            // needs the signed-in user's ID falls back to
            // `sessionStore.credentials?.userID` in the meantime (see e.g.
            // `PlayerView`'s own use of that fallback).
            //
            // A refused certificate (#466) resumes the same way rather than
            // falling to the login screen: the registry's refusal raises the
            // warning over it, and until it's answered the server is as
            // unreachable as an offline one, so it's marked offline. That
            // also covers a refusal already reported this launch, which
            // raises no second warning.
            let certificateRefused = (error as? URLError)?.isCertificateFailure == true
            if ConnectivityMonitor.shared.isOffline || certificateRefused,
               await resumeFromCache(credentials, client: client) {
                if certificateRefused { ConnectivityMonitor.shared.reportFailure() }
            } else {
                phase = .login
            }
        }
    }

    /// Enters `.main` on the cached session, with no request made. `false`
    /// when the credentials hold no token or user to resume.
    private func resumeFromCache(_ credentials: StoredCredentials, client: JellyfinAPIClient) async -> Bool {
        guard credentials.accessToken != nil, credentials.userID != nil else { return false }
        await Self.restoreCachedSession(credentials, on: client)
        phase = .main
        return true
    }

    private static func restoreCachedSession(_ credentials: StoredCredentials, on client: JellyfinAPIClient) async {
        guard let accessToken = credentials.accessToken else { return }
        await client.restoreSession(
            accessToken: accessToken,
            username: credentials.username,
            password: credentials.authMethod == .password ? credentials.password ?? "" : nil
        )
    }

    /// Leaves the first-run welcome for server setup, for good.
    func completeWelcome() {
        sessionStore.markWelcomeCompleted()
    }

    func completeServerSetup(_ configuration: ServerConfiguration) {
        sessionStore.saveServer(configuration)
        // The saved trust first, then setup's candidates go: no moment
        // without one. Setup leaves only through here or by quitting, which
        // takes the in-memory candidates with it.
        trustRegistry.configure(server: configuration)
        trustRegistry.clearCandidates()
        apiClient = JellyfinAPIClient(baseURL: configuration.baseURL)
        phase = .login
    }

    @discardableResult
    func signIn(username: String, password: String) async throws -> UserDto {
        guard let client = apiClient else { throw JellyfinAPIError.invalidServerAddress }
        return try await signIn(username: username, password: password, client: client)
    }

    @discardableResult
    private func signIn(username: String, password: String, client: JellyfinAPIClient) async throws -> UserDto {
        let result = try await client.authenticate(username: username, password: password)
        currentUser = result.user
        sessionStore.saveCredentials(StoredCredentials(
            username: username,
            password: password,
            accessToken: result.accessToken,
            userID: result.user.id,
            serverID: sessionStore.serverConfiguration?.id
        ))
        phase = .main
        return result.user
    }

    /// Completes a Quick Connect sign-in once another client has approved
    /// the code: exchanges the approved `secret` for a session. The username
    /// is stored so the login screen can still prefill it after a sign-out.
    @discardableResult
    func signInWithQuickConnect(secret: String) async throws -> UserDto {
        guard let client = apiClient else { throw JellyfinAPIError.invalidServerAddress }
        let result = try await client.authenticateWithQuickConnect(secret: secret)
        currentUser = result.user
        sessionStore.saveCredentials(StoredCredentials(
            username: result.user.name,
            password: nil,
            accessToken: result.accessToken,
            userID: result.user.id,
            authMethod: .quickConnect,
            serverID: sessionStore.serverConfiguration?.id
        ))
        phase = .main
        return result.user
    }

    /// Launch-time counterpart of `signIn` for a Quick Connect session, which
    /// has no password to sign in with again: its stored token is the whole
    /// credential, so this checks it still works. A token the server has
    /// revoked answers 401 and throws, landing on `.login` like a stale
    /// password does; an unreachable server throws a connectivity error,
    /// which `start()` resumes from cache.
    private func resumeQuickConnectSession(_ credentials: StoredCredentials, client: JellyfinAPIClient) async throws {
        guard let accessToken = credentials.accessToken else { throw JellyfinAPIError.notAuthenticated }
        await client.restoreSession(accessToken: accessToken, username: credentials.username, password: nil)
        currentUser = try await client.currentUser()
        phase = .main
    }

    /// One press on a remembered account on Who's Watching? (tvOS): signs in
    /// the way launch restores a session. A password account signs in again
    /// with its stored password; a Quick Connect one validates its token. On
    /// failure nothing changes, and the account stays remembered.
    func signIn(rememberedAccount account: StoredCredentials) async throws {
        guard let client = apiClient, let server = sessionStore.serverConfiguration else {
            throw JellyfinAPIError.invalidServerAddress
        }
        // Never replayed against another server, where the same name could be
        // someone else (see `StoredCredentials.serverID`).
        guard account.serverID == server.id else { throw JellyfinAPIError.notAuthenticated }
        switch account.authMethod {
        case .password:
            try await signIn(username: account.username, password: account.password ?? "", client: client)
        case .quickConnect:
            try await resumeQuickConnectSession(account, client: client)
            // Launch finds these already stored; here they become current.
            sessionStore.saveCredentials(account)
        }
    }

    func signOut() {
        sessionStore.clearCredentials()
        currentUser = nil
        phase = .login
        // `apiClient` itself is reused across a sign-out/sign-back-in on
        // the same server (only `changeServer()` discards it) — without
        // this, it would keep the just-signed-out user's credentials
        // around to silently re-authenticate with if a request from
        // before sign-out was still in flight. Fire-and-forget: nothing
        // here needs to block the UI on this actor hop completing.
        if let apiClient {
            Task { await apiClient.forgetReauthCredentials() }
        }
    }

    #if os(tvOS)
    /// Profile's Sign Out: forgets this account on this Apple TV, then signs
    /// out. Switch User (`signOut()`) keeps it remembered, one press away on
    /// Who's Watching?; this is for someone who is leaving for good.
    func signOutForgettingAccount() {
        if let userID = sessionStore.credentials?.userID {
            sessionStore.forgetAccount(userID: userID)
        }
        signOut()
    }

    /// The "Follow Apple TV Users" setting. The session moves with it, so
    /// whoever is signed in stays signed in (`ServerSessionStore.moveSession`).
    func setFollowsAppleTVUsers(_ follows: Bool) {
        // The session first: if it can't be moved, the setting stays as it
        // was and still points at where the session is.
        guard sessionStore.moveSession(to: follows ? .currentUser : .allUsers) else { return }
        SessionScopeSetting.set(follows)
    }

    private var asksWhoIsWatching: Bool {
        let accounts = sessionStore.serverConfiguration.map { sessionStore.rememberedAccounts(forServer: $0.id).count } ?? 0
        return WhoIsWatchingPolicy.asks(
            followsAppleTVUsers: SessionScopeSetting.followsAppleTVUsers,
            selectsUserEveryRelaunch: SessionScopeSetting.selectsUserEveryRelaunch,
            rememberedAccounts: accounts
        )
    }

    func didEnterBackground(at date: Date = Date()) {
        backgroundedAt = date
    }

    /// Whether coming back to the foreground should return to Who's
    /// Watching?: signed in, away for `WhoIsWatchingPolicy.timeAway` or more,
    /// and the settings ask. The caller closes the player and signs out.
    /// Each time away is answered once.
    func asksWhoIsWatching(returningAt date: Date = Date()) -> Bool {
        guard let left = backgroundedAt else { return false }
        backgroundedAt = nil
        return phase == .main && WhoIsWatchingPolicy.asks(afterSecondsAway: date.timeIntervalSince(left)) && asksWhoIsWatching
    }
    #endif

    /// Forgets the server entirely and returns to first-run setup.
    func changeServer() {
        sessionStore.clearAll()
        certificateWarning = nil
        trustRegistry.configure(server: nil)
        trustRegistry.clearCandidates()
        currentUser = nil
        apiClient = nil
        phase = .serverSetup
    }

    // MARK: The certificate warning (#466)

    /// Hears the registry's refusals, which arrive off the main actor at most
    /// once per presented certificate per launch. The certificate is read on
    /// a detached task (that evaluates it, and the refused handshake shouldn't
    /// wait on it), and the warning raised on the main actor.
    ///
    /// A certificate counts as reported only once it raises the warning: one
    /// that raises nothing (unreadable, another origin, or another warning
    /// already up) is handed back to the registry, so its next refusal is
    /// reported again. The one shown stays reported, so Not Now isn't asked
    /// again for it this launch.
    private func observeRefusals() {
        let registry = trustRegistry
        trustRegistry.onRefusal = { [weak self] refusal in
            Task.detached { [weak self] in
                guard let details = ServerCertificateDetails(chain: refusal.presentedChain) else {
                    registry.forgetReport(of: refusal.presentedLeaf)
                    return
                }
                await self?.raiseCertificateWarning(for: refusal, details: details)
            }
        }
    }

    /// Only for the configured server: a refusal at another origin is setup's
    /// candidate, which the setup offer answers. A warning already up stays.
    /// A refusal decided under a trust that has since changed (its details
    /// are read off the main actor, so it can land after Trust) is stale: it
    /// is handed back, and the next refusal reports against the trust held.
    private func raiseCertificateWarning(for refusal: ServerTrustRefusal, details: ServerCertificateDetails) {
        guard certificateWarning == nil,
              let server = sessionStore.serverConfiguration,
              refusal.origin == server.origin,
              refusal.previous == server.certificateTrust else {
            trustRegistry.forgetReport(of: refusal.presentedLeaf)
            return
        }
        certificateWarning = CertificateWarning(
            kind: refusal.previous.map { .changed(previous: $0) } ?? .untrusted,
            details: details
        )
    }

    /// "Trust New Certificate": saves the presented certificate's trust for
    /// the server and restarts the session under it, in place (no Who's
    /// Watching? on the Apple TV).
    ///
    /// Marked offline first: whatever failed under the refusal (Home's rails)
    /// reloads when the restart's first response marks it online again, as
    /// after any outage. Any HTTP answer clears it, a 401 included. Only when
    /// there's a session for the restart to sign in (`start()` makes no
    /// request without one), or nothing would mark it online again.
    func trustPresentedCertificate() async {
        guard let warning = certificateWarning, var server = sessionStore.serverConfiguration else { return }
        server.certificateTrust = warning.details.trust
        sessionStore.saveServer(server)
        trustRegistry.configure(server: server)
        certificateWarning = nil
        if let credentials = sessionStore.credentials, credentials.serverID == nil || credentials.serverID == server.id {
            ConnectivityMonitor.shared.reportFailure()
        }
        await start(isRelaunch: false)
        // The restart reuses the client (`start`). Landing anywhere but
        // `.main` (no session, another server's, a sign-in refused), it must
        // not keep the previous session's credentials to re-authenticate
        // with, as after `signOut()`.
        if phase != .main, let apiClient {
            await apiClient.forgetReauthCredentials()
        }
    }

    /// "Not Now (Stay Offline)": trusts nothing and carries on offline, as
    /// launch does when the server can't be reached, so Downloads keep
    /// working (on the Apple TV, which has none, Home's offline state).
    /// Outside `.main` only the launch still in flight resumes the cached
    /// session; anywhere else (the login screen, whose stored session the
    /// server may have refused) it stays where it is. The same certificate
    /// isn't reported again this launch; another one is.
    func stayOfflineForNow() {
        certificateWarning = nil
        if phase == .main {
            ConnectivityMonitor.shared.reportFailure()
            return
        }
        guard isRestoringSession,
              let credentials = sessionStore.credentials,
              credentials.accessToken != nil, credentials.userID != nil,
              let client = apiClient
        else { return }
        ConnectivityMonitor.shared.reportFailure()
        phase = .main
        Task { await Self.restoreCachedSession(credentials, on: client) }
    }

    /// The warning couldn't be put on screen at all (the presenter ran out
    /// of tries, `CertificateWarningPresentationAttempts`): carries on as
    /// Not Now would, offline, but nothing was answered, so the certificate
    /// is handed back to the registry and its next refusal raises the
    /// warning again.
    func withdrawUnshownCertificateWarning() {
        guard let warning = certificateWarning else { return }
        stayOfflineForNow()
        trustRegistry.forgetReport(of: warning.details.leaf)
    }
}

/// What `AppState` raises when the configured server's certificate is
/// refused (#466).
struct CertificateWarning: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A trust is stored and this certificate doesn't meet it.
        case changed(previous: ServerCertificateTrust)
        /// No trust is stored and the system refuses the certificate (a
        /// lapsed renewal, a removed CA profile): the setup offer's details.
        case untrusted
    }

    let kind: Kind
    let details: ServerCertificateDetails
    var id: Data { details.fingerprint }
}
