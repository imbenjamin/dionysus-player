import Foundation
@testable import Dionysus

/// Storage that lives and dies with the test, for the stores built on
/// `AudioOffsetStorage` (Night Mode's among them).
final class InMemoryStorage: AudioOffsetStorage {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

extension NightModeController {
    /// Night Mode off, over an in-memory store and with no wakes, so a
    /// `PlayerViewModel` under test never reads the device's own Night Mode
    /// (`.shared`) or starts its timers and observers.
    @MainActor
    static func isolated() -> NightModeController {
        NightModeController(store: NightModeStore(storage: InMemoryStorage()), schedulesWakes: false)
    }
}
