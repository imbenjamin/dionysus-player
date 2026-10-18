import Foundation

/// The audio offset: one global value and per-title overrides, in whole
/// milliseconds.
///
/// Device-local `UserDefaults`, never sent to the server. **Not keyed by user**,
/// unlike `TrackPreferenceStore`: an offset corrects this device's audio chain
/// (a soundbar, an AVR, a TV's processing), which is the same whoever is
/// signed in (Benjamin, 2026-10-18). Per-title entries are keyed by item id
/// alone, so streaming and a download share one, as track choices do.
///
/// Every read and write goes through `AudioOffset.normalized(_:)`, so nothing
/// out of range or off-step can reach the engine from here.
final class AudioOffsetStore {
    static let globalKey = "audioOffset.global"
    static let titlesKey = "audioOffset.titles"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var globalOffsetMilliseconds: Int {
        get { AudioOffset.normalized(defaults.integer(forKey: Self.globalKey)) }
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

    private var titles: [String: Int] {
        defaults.dictionary(forKey: Self.titlesKey) as? [String: Int] ?? [:]
    }
}
