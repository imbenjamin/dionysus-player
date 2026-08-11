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

    let sessionStore: ServerSessionStore

    init(sessionStore: ServerSessionStore = ServerSessionStore()) {
        self.sessionStore = sessionStore
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
            // Remembered credentials no longer work; fall back to manual sign-in.
            phase = .login
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
    }

    /// Forgets the server entirely and returns to first-run setup.
    func changeServer() {
        sessionStore.clearAll()
        currentUser = nil
        apiClient = nil
        phase = .serverSetup
    }
}
