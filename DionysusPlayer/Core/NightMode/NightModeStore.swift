import Foundation

/// Night Mode's settings, per device and shared by every user on it, like the
/// Spatial Audio settings: they describe the room, not the person. On tvOS
/// that's the keychain every Apple TV user shares; on iOS `UserDefaults`.
final class NightModeStore {
    static let isOnKey = "nightMode.isOn"
    static let nightAudioKey = "nightMode.nightAudio"
    static let volumeKey = "nightMode.volumePercent"
    static let brightnessKey = "nightMode.brightnessPercent"
    static let scheduleEnabledKey = "nightMode.schedule.enabled"
    static let turnOnKey = "nightMode.schedule.turnOn"
    static let turnOffKey = "nightMode.schedule.turnOff"
    static let lastBoundaryKey = "nightMode.lastBoundaryApplied"

    private let storage: AudioOffsetStorage

    init(storage: AudioOffsetStorage = AudioOffsetStore.platformStorage) {
        self.storage = storage
    }

    var settings: NightModeSettings {
        get {
            let defaults = NightModeSettings.defaults
            return NightModeSettings(
                isOn: bool(forKey: Self.isOnKey, default: defaults.isOn),
                nightAudio: bool(forKey: Self.nightAudioKey, default: defaults.nightAudio),
                volumePercent: level(forKey: Self.volumeKey, default: defaults.volumePercent),
                brightnessPercent: level(forKey: Self.brightnessKey, default: defaults.brightnessPercent),
                schedule: NightModeSchedule(
                    isEnabled: bool(forKey: Self.scheduleEnabledKey, default: defaults.schedule.isEnabled),
                    turnOn: time(forKey: Self.turnOnKey, default: defaults.schedule.turnOn),
                    turnOff: time(forKey: Self.turnOffKey, default: defaults.schedule.turnOff)
                )
            )
        }
        set {
            storage.set(newValue.isOn, forKey: Self.isOnKey)
            storage.set(newValue.nightAudio, forKey: Self.nightAudioKey)
            storage.set(NightModeLevel.clamped(newValue.volumePercent), forKey: Self.volumeKey)
            storage.set(NightModeLevel.clamped(newValue.brightnessPercent), forKey: Self.brightnessKey)
            storage.set(newValue.schedule.isEnabled, forKey: Self.scheduleEnabledKey)
            storage.set(newValue.schedule.turnOn.minutesSinceMidnight, forKey: Self.turnOnKey)
            storage.set(newValue.schedule.turnOff.minutesSinceMidnight, forKey: Self.turnOffKey)
        }
    }

    /// The last schedule boundary acted on, so a missed one applies once on
    /// the next launch and none applies twice. Stored as seconds since 1970.
    var lastBoundaryApplied: Date? {
        get {
            (storage.object(forKey: Self.lastBoundaryKey) as? Double)
                .map { Date(timeIntervalSince1970: $0) }
        }
        set {
            storage.set(newValue?.timeIntervalSince1970, forKey: Self.lastBoundaryKey)
        }
    }

    /// Every value gone, back to the defaults, for the UI-test harness's
    /// reset.
    func removeAll() {
        for key in [Self.isOnKey, Self.nightAudioKey, Self.volumeKey, Self.brightnessKey,
                    Self.scheduleEnabledKey, Self.turnOnKey, Self.turnOffKey, Self.lastBoundaryKey] {
            storage.set(nil, forKey: key)
        }
    }

    /// A Bool, or a string standing for one: a launch argument
    /// (`-nightMode.schedule.enabled YES`) reaches `UserDefaults`' argument
    /// domain as a string, which `as? Bool` alone ignored. "YES", "true" and
    /// "1" read true, as `NSString.boolValue` reads them; anything else
    /// stored, or nothing, is the default.
    private func bool(forKey key: String, default fallback: Bool) -> Bool {
        switch storage.object(forKey: key) {
        case let value as Bool: value
        case let value as String: (value as NSString).boolValue
        default: fallback
        }
    }

    /// An Int, or a string of one, for the same reason as `bool`.
    private func int(forKey key: String) -> Int? {
        switch storage.object(forKey: key) {
        case let value as Int: value
        case let value as String: Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// A stored level off the step or out of range (another build's) reads
    /// snapped and clamped.
    private func level(forKey key: String, default fallback: Int) -> Int {
        guard let stored = int(forKey: key) else { return fallback }
        return NightModeLevel.clamped(stored)
    }

    private func time(forKey key: String, default fallback: TimeOfDay) -> TimeOfDay {
        guard let stored = int(forKey: key) else { return fallback }
        return TimeOfDay(minutesSinceMidnight: stored)
    }
}
