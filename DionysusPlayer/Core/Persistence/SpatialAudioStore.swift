import Foundation

/// The two Spatial Audio settings, per device and shared by every user on it,
/// as the audio offset is: they describe the hardware, not the person. On
/// tvOS that's the keychain every Apple TV user shares; on iOS `UserDefaults`.
final class SpatialAudioStore {
    static let atmosEnabledKey = "spatialAudio.atmos.enabled"
    static let atmosLayoutKey = "spatialAudio.atmos.layout"
    static let dtsXEnabledKey = "spatialAudio.dtsx.enabled"
    static let dtsXLayoutKey = "spatialAudio.dtsx.layout"

    private let storage: AudioOffsetStorage

    init(storage: AudioOffsetStorage = AudioOffsetStore.platformStorage) {
        self.storage = storage
    }

    var settings: SpatialAudioSettings {
        get {
            SpatialAudioSettings(
                atmosEnabled: storage.object(forKey: Self.atmosEnabledKey) as? Bool ?? false,
                atmosLayout: layout(forKey: Self.atmosLayoutKey, format: .dolbyAtmos),
                dtsXEnabled: storage.object(forKey: Self.dtsXEnabledKey) as? Bool ?? false,
                dtsXLayout: layout(forKey: Self.dtsXLayoutKey, format: .dtsX)
            )
        }
        set {
            storage.set(newValue.atmosEnabled, forKey: Self.atmosEnabledKey)
            storage.set(newValue.atmosLayout.rawValue, forKey: Self.atmosLayoutKey)
            storage.set(newValue.dtsXEnabled, forKey: Self.dtsXEnabledKey)
            storage.set(newValue.dtsXLayout.rawValue, forKey: Self.dtsXLayoutKey)
        }
    }

    /// A stored layout the format can't render (or another build's garbage)
    /// reads as the default.
    private func layout(forKey key: String, format: SpatialAudioFormat) -> SpeakerLayout {
        guard let raw = storage.object(forKey: key) as? String,
              let layout = SpeakerLayout(rawValue: raw), format.layouts.contains(layout)
        else { return SpatialAudioFormat.defaultLayout }
        return layout
    }

    /// All four values gone, for the UI-test harness's reset.
    func removeAll() {
        for key in [Self.atmosEnabledKey, Self.atmosLayoutKey, Self.dtsXEnabledKey, Self.dtsXLayoutKey] {
            storage.set(nil, forKey: key)
        }
    }
}
