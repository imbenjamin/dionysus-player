import Foundation
import Observation

/// Persists the configured server and the signed-in user's credentials
/// across launches. Server config lives in `UserDefaults` (not secret);
/// credentials live in the Keychain.
@Observable
final class ServerSessionStore {
    private enum Keys {
        static let serverConfiguration = "server.configuration"
        static let credentials = "server.credentials"
        static let welcomeCompleted = "onboarding.welcomeCompleted"
    }

    private(set) var serverConfiguration: ServerConfiguration?
    private(set) var credentials: StoredCredentials?
    /// Whether the first-run welcome is behind the user: they tapped "Get
    /// Started", or have ever configured a server — which covers everyone
    /// who set the app up before the welcome existed. Never cleared by
    /// `clearAll()`: changing server or signing out shouldn't replay an
    /// introduction to an app the user already has.
    private(set) var hasCompletedWelcome = false

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadServerConfiguration()
        loadCredentials()
        hasCompletedWelcome = defaults.bool(forKey: Keys.welcomeCompleted)
        // Someone who set the app up before the welcome existed: written, not
        // just inferred, or it would be forgotten the moment `clearAll()`
        // removed the server it was inferred from.
        if serverConfiguration != nil, !hasCompletedWelcome {
            markWelcomeCompleted()
        }
    }

    private func loadServerConfiguration() {
        guard let data = defaults.data(forKey: Keys.serverConfiguration),
              let config = try? decoder.decode(ServerConfiguration.self, from: data) else { return }
        serverConfiguration = config
    }

    private func loadCredentials() {
        guard let data = KeychainStore.load(forKey: Keys.credentials),
              let creds = try? decoder.decode(StoredCredentials.self, from: data) else { return }
        credentials = creds
    }

    func saveServer(_ configuration: ServerConfiguration) {
        markWelcomeCompleted()
        serverConfiguration = configuration
        guard let data = try? encoder.encode(configuration) else { return }
        defaults.set(data, forKey: Keys.serverConfiguration)
    }

    func saveCredentials(_ credentials: StoredCredentials) {
        self.credentials = credentials
        guard let data = try? encoder.encode(credentials) else { return }
        KeychainStore.save(data, forKey: Keys.credentials)
    }

    /// Signs the user out but keeps the server configured, so they land
    /// back on the login screen rather than server setup.
    func clearCredentials() {
        credentials = nil
        KeychainStore.delete(forKey: Keys.credentials)
    }

    /// Forgets the server entirely, sending the user back to first-run setup.
    func markWelcomeCompleted() {
        hasCompletedWelcome = true
        defaults.set(true, forKey: Keys.welcomeCompleted)
    }

    func clearAll() {
        clearCredentials()
        serverConfiguration = nil
        defaults.removeObject(forKey: Keys.serverConfiguration)
    }
}
