import Foundation

// Kept out of `ServerTrustRegistry.swift`: the Top Shelf extension compiles
// `Core/Networking` but not `ServerSessionStore`.
extension ServerTrustRegistry {
    /// Fills the trust from the saved server at launch, before any session
    /// can raise a challenge: a background relaunch for downloads can reach
    /// `URLSession` before `AppState.start()` runs (#466).
    func loadFromStore(_ store: ServerSessionStore) {
        configure(server: store.serverConfiguration)
    }
}
