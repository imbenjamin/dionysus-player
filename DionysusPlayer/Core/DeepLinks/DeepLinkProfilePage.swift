import Foundation

extension DeepLink {
    /// A page in Profile that a `dionysus://profile/…` or
    /// `dionysus://quickconnect/approve` link opens (#406). Each app shows it
    /// its own way: iPhone and iPad as a pane or a push, the Apple TV as a
    /// cover over its one Profile page.
    enum ProfilePage: Equatable, Sendable {
        case root
        case account
        case appearance
        case playback
        case advancedPlayback
        case downloads
        case about
        case license
        case privacyPolicy
        /// Account → Quick Connect, with the code filled in, never submitted.
        case quickConnect(code: String?)

        /// The page a `profile` link's path names; nil for one Profile
        /// doesn't have, which opens Profile and says so.
        init?(path: [String]) {
            switch path.map { $0.lowercased() } {
            case []: self = .root
            case ["account"]: self = .account
            case ["appearance"]: self = .appearance
            case ["playback"]: self = .playback
            case ["playback", "advanced"]: self = .advancedPlayback
            case ["downloads"]: self = .downloads
            case ["about"]: self = .about
            case ["about", "license"]: self = .license
            case ["about", "privacy"]: self = .privacyPolicy
            default: return nil
            }
        }

        /// What the app says when a link names a page Profile doesn't have.
        static var notFoundMessage: String { String(localized: "Profile has no such page.") }
    }
}

/// A Profile page a link asked for, handed to Profile by each app's shell;
/// a new id opens it again even when it's the same page.
struct LinkedProfilePage: Equatable, Sendable {
    let id = UUID()
    let page: DeepLink.ProfilePage
}

extension DeepLink {
    /// What the Apple TV says about a link to Downloads, which it doesn't have.
    static var noDownloadsMessage: String { String(localized: "Downloads aren't on Apple TV.") }
}
