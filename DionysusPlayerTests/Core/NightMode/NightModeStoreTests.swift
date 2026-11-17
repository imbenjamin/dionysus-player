import XCTest
@testable import Dionysus

final class NightModeStoreTests: XCTestCase {
    private final class MemoryStorage: AudioOffsetStorage {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    private var storage: MemoryStorage!
    private var store: NightModeStore!

    override func setUp() {
        super.setUp()
        storage = MemoryStorage()
        store = NightModeStore(storage: storage)
    }

    func test_defaults_whenNothingStored() {
        XCTAssertEqual(store.settings, NightModeSettings.defaults)
        XCTAssertFalse(store.settings.isOn)
        XCTAssertTrue(store.settings.nightAudio)
        XCTAssertEqual(store.settings.volumePercent, 100)
        XCTAssertEqual(store.settings.brightnessPercent, 100)
        XCTAssertFalse(store.settings.schedule.isEnabled)
        XCTAssertEqual(store.settings.schedule.turnOn, TimeOfDay(hour: 22, minute: 0))
        XCTAssertEqual(store.settings.schedule.turnOff, TimeOfDay(hour: 7, minute: 0))
        XCTAssertNil(store.lastBoundaryApplied)
    }

    func test_roundTrip_keepsEveryField() {
        let settings = NightModeSettings(
            isOn: true,
            nightAudio: false,
            volumePercent: 60,
            brightnessPercent: 35,
            schedule: NightModeSchedule(
                isEnabled: true,
                turnOn: TimeOfDay(hour: 21, minute: 45),
                turnOff: TimeOfDay(hour: 6, minute: 30)
            )
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.settings = settings
        store.lastBoundaryApplied = date

        let reread = NightModeStore(storage: storage)
        XCTAssertEqual(reread.settings, settings)
        XCTAssertEqual(reread.lastBoundaryApplied, date)

        reread.lastBoundaryApplied = nil
        XCTAssertNil(store.lastBoundaryApplied)
    }

    /// The UI-test harness's reset: every key gone, so the next read is the
    /// defaults and no schedule boundary is remembered.
    func test_removeAll_returnsToTheDefaults() {
        store.settings = NightModeSettings(
            isOn: true, nightAudio: false, volumePercent: 60, brightnessPercent: 35,
            schedule: NightModeSchedule(isEnabled: true, turnOn: TimeOfDay(hour: 21, minute: 0), turnOff: TimeOfDay(hour: 6, minute: 0))
        )
        store.lastBoundaryApplied = Date(timeIntervalSince1970: 1_800_000_000)

        store.removeAll()

        XCTAssertTrue(storage.values.isEmpty, "Left behind: \(storage.values.keys.sorted())")
        XCTAssertEqual(store.settings, NightModeSettings.defaults)
        XCTAssertNil(store.lastBoundaryApplied)
    }

    /// A launch argument (`-nightMode.schedule.enabled YES`) reaches
    /// `UserDefaults` as a string, not a Bool; it's read as one.
    func test_bools_readFromStrings() {
        storage.set("YES", forKey: NightModeStore.scheduleEnabledKey)
        storage.set("true", forKey: NightModeStore.isOnKey)
        storage.set("NO", forKey: NightModeStore.nightAudioKey)
        XCTAssertTrue(store.settings.schedule.isEnabled)
        XCTAssertTrue(store.settings.isOn)
        XCTAssertFalse(store.settings.nightAudio)

        storage.set("false", forKey: NightModeStore.scheduleEnabledKey)
        XCTAssertFalse(store.settings.schedule.isEnabled)
    }

    /// The same through `UserDefaults`, where the argument domain puts a
    /// launch argument's value as a string.
    func test_bools_readFromAStringInUserDefaults() {
        let suite = "NightModeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("YES", forKey: NightModeStore.scheduleEnabledKey)
        XCTAssertTrue(NightModeStore(storage: defaults).settings.schedule.isEnabled)
    }

    /// A number written as a string (`-nightMode.volumePercent 50`) reads as
    /// one too; anything else falls back to the default.
    func test_levelsAndTimes_readFromStrings() {
        storage.set("50", forKey: NightModeStore.volumeKey)
        storage.set("1290", forKey: NightModeStore.turnOnKey)
        storage.set("loud", forKey: NightModeStore.brightnessKey)
        XCTAssertEqual(store.settings.volumePercent, 50)
        XCTAssertEqual(store.settings.schedule.turnOn, TimeOfDay(hour: 21, minute: 30))
        XCTAssertEqual(store.settings.brightnessPercent, 100)
    }

    func test_bools_unreadableOrAbsent_fallBackToTheDefault() {
        XCTAssertTrue(store.settings.nightAudio, "absent")
        storage.set(Data(), forKey: NightModeStore.nightAudioKey)
        XCTAssertTrue(store.settings.nightAudio, "not a Bool or a string")
    }

    func test_levels_clampAndSnapToFive() {
        XCTAssertEqual(NightModeLevel.clamped(-5), 0)
        XCTAssertEqual(NightModeLevel.clamped(103), 100)
        XCTAssertEqual(NightModeLevel.clamped(42), 40)
        XCTAssertEqual(NightModeLevel.clamped(43), 45)

        storage.set(43, forKey: NightModeStore.volumeKey)
        XCTAssertEqual(store.settings.volumePercent, 45)
    }

    func test_effect_offIsNone() {
        var settings = NightModeSettings.defaults
        settings.isOn = false
        settings.volumePercent = 30
        settings.brightnessPercent = 30
        XCTAssertEqual(settings.effect, .none)
    }

    func test_effect_onMapsLevels() {
        var settings = NightModeSettings.defaults
        settings.isOn = true
        settings.volumePercent = 60
        settings.brightnessPercent = 40
        XCTAssertTrue(settings.effect.nightAudio)
        XCTAssertEqual(settings.effect.volume, 0.6, accuracy: 0.0001)
        XCTAssertEqual(settings.effect.dimOpacity, 0.6, accuracy: 0.0001)
    }
}
