import AetherEngine
import Foundation

/// Hands `ServerTrustRegistry`'s answers to AetherEngine's sessions (#466).
/// The evaluator is set only while a trust is stored: with any evaluator set
/// the engine adds a system-trust handshake to every `https` transcode load,
/// a cost servers with no trust shouldn't pay.
enum ServerTrustEngineBridge {
    /// Points `ServerTrustRegistry.didChange` here for `.shared` and applies
    /// it once. Call at launch, before the registry is loaded. Registries
    /// other than `.shared` (tests') never reach the engine.
    static func install() {
        ServerTrustRegistry.didChange = { registry in
            guard registry === ServerTrustRegistry.shared else { return }
            apply(registry: registry)
        }
        apply(registry: .shared)
    }

    /// Not serialized: `didChange` runs outside the registry's lock, so two
    /// changes made on different threads could land here in either order.
    /// Every change to `.shared` today is made on the main actor (launch,
    /// `AppState`, setup), which orders them; a change made off it would need
    /// this to hop there first.
    static func apply(registry: ServerTrustRegistry) {
        guard registry.hasStoredTrust else {
            EngineTLS.serverTrustEvaluator = nil
            return
        }
        EngineTLS.serverTrustEvaluator = { @Sendable space in
            guard let trust = space.serverTrust else { return false }
            return registry.decide(trust, host: space.host, port: space.port) == .accept
        }
    }
}
