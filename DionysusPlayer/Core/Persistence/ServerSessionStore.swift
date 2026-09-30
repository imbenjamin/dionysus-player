import Foundation
import Observation

/// Persists the configured server and the signed-in user's credentials
/// across launches. Server config lives in `UserDefaults` on iOS and in the
/// keychain every Apple TV user shares on tvOS; credentials live in the
/// (per-user) Keychain.
@Observable
final class ServerSessionStore {
    private enum Keys {
        static let serverConfiguration = "server.configuration"
        static let credentials = "server.credentials"
        static let welcomeCompleted = "onboarding.welcomeCompleted"
    }

    /// Where the configured server is kept. On tvOS it's the household's, not
    /// one person's: it goes in the keychain every Apple TV user shares, while
    /// each person's credentials stay in their own. It also survives a
    /// reinstall there, alongside the credentials, which `UserDefaults`
    /// doesn't. That mismatch is the likeliest cause of the spike's one
    /// unexplained session loss.
    enum ServerLocation {
        case userDefaults
        case sharedKeychain

        static var platformDefault: ServerLocation {
            #if os(tvOS)
            .sharedKeychain
            #else
            .userDefaults
            #endif
        }
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
    private let serverLocation: ServerLocation
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard, serverLocation: ServerLocation = .platformDefault) {
        self.defaults = defaults
        self.serverLocation = serverLocation
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
        let data: Data? = switch serverLocation {
        case .userDefaults: defaults.data(forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.load(forKey: Keys.serverConfiguration, scope: .allUsers)
        }
        guard let data, let config = try? decoder.decode(ServerConfiguration.self, from: data) else { return }
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
        switch serverLocation {
        case .userDefaults: defaults.set(data, forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.save(data, forKey: Keys.serverConfiguration, scope: .allUsers)
        }
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

    /// Records that the first-run welcome is behind the user.
    func markWelcomeCompleted() {
        hasCompletedWelcome = true
        defaults.set(true, forKey: Keys.welcomeCompleted)
    }

    /// Forgets the server entirely, sending the user back to first-run setup.
    func clearAll() {
        clearCredentials()
        serverConfiguration = nil
        switch serverLocation {
        case .userDefaults: defaults.removeObject(forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.delete(forKey: Keys.serverConfiguration, scope: .allUsers)
        }
    }
}
