import Foundation

/// The audio offset: one global value and per-title overrides, in whole
/// milliseconds.
///
/// Stored on the device, never sent to the server. **Not keyed by user**,
/// unlike `TrackPreferenceStore`: an offset corrects this device's audio chain
/// (a soundbar, an AVR, a TV's processing), which is the same whoever is
/// signed in (Benjamin, 2026-10-18). Per-title entries are keyed by item id
/// alone, so streaming and a download share one, as track choices do.
///
/// "Per device" is why tvOS stores it in the keychain every Apple TV user
/// shares (`SharedKeychainAudioOffsetStorage`): the app runs as the current
/// Apple TV user there, so its `UserDefaults` is per user, and switching user
/// would otherwise lose the calibration. iOS has one user and keeps
/// `UserDefaults`.
///
/// Every read and write goes through `AudioOffset.normalized(_:)`, so nothing
/// out of range or off-step can reach the engine from here.
final class AudioOffsetStore {
    static let globalKey = "audioOffset.global"
    static let titlesKey = "audioOffset.titles"

    static var platformStorage: AudioOffsetStorage {
        #if os(tvOS)
        SharedKeychainAudioOffsetStorage()
        #else
        UserDefaults.standard
        #endif
    }

    private let defaults: AudioOffsetStorage

    init(storage: AudioOffsetStorage = AudioOffsetStore.platformStorage) {
        self.defaults = storage
    }

    convenience init(defaults: UserDefaults) {
        self.init(storage: defaults)
    }

    var globalOffsetMilliseconds: Int {
        get { AudioOffset.normalized(defaults.object(forKey: Self.globalKey) as? Int ?? 0) }
        set { defaults.set(AudioOffset.normalized(newValue), forKey: Self.globalKey) }
    }

    func offset(forItem itemID: String) -> Int? {
        titles[itemID].map(AudioOffset.normalized)
    }

    func setOffset(_ milliseconds: Int, forItem itemID: String) {
        var map = titles
        map[itemID] = AudioOffset.normalized(milliseconds)
        defaults.set(map, forKey: Self.titlesKey)
    }

    func removeOffset(forItem itemID: String) {
        var map = titles
        guard map.removeValue(forKey: itemID) != nil else { return }
        defaults.set(map, forKey: Self.titlesKey)
    }

    /// Entry by entry, so one that isn't a number (another build's, or a
    /// corrupted one) is dropped alone instead of taking every title with it
    /// at the next write.
    private var titles: [String: Int] {
        let stored = defaults.object(forKey: Self.titlesKey) as? [String: Any] ?? [:]
        return stored.compactMapValues { ($0 as? NSNumber)?.intValue }
    }
}

/// Where `AudioOffsetStore` keeps its two values. `UserDefaults` already
/// conforms.
protocol AudioOffsetStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: AudioOffsetStorage {}

/// The keychain every Apple TV user shares (`KeychainStore.Scope.allUsers`),
/// each value a property list. On iOS that's the one keychain.
final class SharedKeychainAudioOffsetStorage: AudioOffsetStorage {
    private let keyPrefix: String

    /// `keyPrefix` keeps tests' entries apart from the app's.
    init(keyPrefix: String = "") {
        self.keyPrefix = keyPrefix
    }

    func object(forKey key: String) -> Any? {
        guard let data = KeychainStore.load(forKey: keyPrefix + key, scope: .allUsers) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    func set(_ value: Any?, forKey key: String) {
        guard let value,
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        else {
            KeychainStore.delete(forKey: keyPrefix + key, scope: .allUsers)
            return
        }
        KeychainStore.save(data, forKey: keyPrefix + key, scope: .allUsers)
    }

    /// Both values gone, for the UI-test harness's reset and tests.
    func removeAll() {
        set(nil, forKey: AudioOffsetStore.globalKey)
        set(nil, forKey: AudioOffsetStore.titlesKey)
    }
}
