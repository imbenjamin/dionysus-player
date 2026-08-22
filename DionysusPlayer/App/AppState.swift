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
        /// Session restore at launch couldn't reach the server at all
        /// (distinct from `.login`, which also covers a user actively
        /// signing in manually — see `start()`'s doc comment).
        case offline
    }

    private(set) var phase: Phase = .serverSetup
    private(set) var isRestoringSession = true
    private(set) var currentUser: UserDto?
    private(set) var apiClient: JellyfinAPIClient?

    let sessionStore: ServerSessionStore
    /// Offline downloads are local-device storage, not tied to which
    /// server is configured — unlike `apiClient`, this is created once
    /// here and never recreated on sign-out/change-server, so an in-flight
    /// download survives a session change untouched.
    let downloadManager: DownloadManager

    init(sessionStore: ServerSessionStore = ServerSessionStore(), downloadManager: DownloadManager = DownloadManager()) {
        self.sessionStore = sessionStore
        self.downloadManager = downloadManager
        // See `DownloadManager.onRowMarkedForDeletion`'s own doc comment
        // for the bug this fixes and why it's wired here (the one place
        // that can resolve a *live* `apiClient`, read fresh through `self`
        // each time this actually fires rather than captured once — it can
        // be recreated or go `nil` across sign-in/sign-out/server changes
        // over this same long-lived `downloadManager`'s lifetime).
        downloadManager.onRowMarkedForDeletion = { [weak self] in
            guard let self, let client = self.apiClient else { return }
            Task { await DownloadSyncManager.syncIfNeeded(client: client, store: self.downloadManager.store) }
        }
    }

    /// Call once at launch: restores the configured server and attempts to
    /// sign the user back in with their remembered credentials.
    func start() async {
        defer { isRestoringSession = false }

        // Fire-and-forget, not awaited: pays CoreMotion's one-time
        // daemon-connection bootstrap cost during the splash/session-restore
        // window instead of whenever the user first reaches the "3D Depth
        // Effects" toggle or a detail page — see
        // `DeviceTiltObserver.warmUp()`'s doc comment. Must never delay
        // showing the actual app once sign-in restore finishes.
        Task { await DeviceTiltObserver.shared.warmUp() }

        guard let server = sessionStore.serverConfiguration else {
            phase = .serverSetup
            return
        }

        let client = JellyfinAPIClient(baseURL: server.baseURL)
        apiClient = client

        guard let credentials = sessionStore.credentials else {
            phase = .login
            return
        }

        do {
            try await signIn(username: credentials.username, password: credentials.password ?? "", client: client)
        } catch {
            // Either the remembered credentials no longer work (fall back to
            // manual sign-in), or the server couldn't be reached at all —
            // `ConnectivityMonitor` reflects this specific attempt's outcome
            // since `sendRaw`'s reporting call is awaited inline in the same
            // chain this catch waits on, so it's never stale here. A 401/other
            // HTTP error still reports success, so bad credentials still land
            // on `.login` as before.
            phase = ConnectivityMonitor.shared.isOffline ? .offline : .login
        }
    }

    func completeServerSetup(_ configuration: ServerConfiguration) {
        sessionStore.saveServer(configuration)
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
            userID: result.user.id
        ))
        phase = .main
        return result.user
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

    /// Forgets the server entirely and returns to first-run setup.
    func changeServer() {
        sessionStore.clearAll()
        currentUser = nil
        apiClient = nil
        phase = .serverSetup
    }
}
