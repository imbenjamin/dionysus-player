import XCTest
@testable import Dionysus

@MainActor
final class NightModeControllerTests: XCTestCase {
    private final class MemoryStorage: AudioOffsetStorage {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    private var calendar: Calendar!
    private var clock: Date!
    private var store: NightModeStore!
    private var controller: NightModeController!

    override func setUp() async throws {
        try await super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        clock = date(day: 10, hour: 12)
        store = NightModeStore(storage: MemoryStorage())
        controller = makeController()
    }

    private func makeController() -> NightModeController {
        NightModeController(store: store, now: { [unowned self] in clock }, calendar: calendar, schedulesWakes: false)
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private let window = NightModeSchedule(
        isEnabled: true,
        turnOn: TimeOfDay(hour: 22, minute: 0),
        turnOff: TimeOfDay(hour: 7, minute: 0)
    )

    func test_setOn_persistsAndChangesEffect() {
        controller.setVolumePercent(50)
        controller.setBrightnessPercent(40)
        XCTAssertEqual(controller.effect, .none)
        controller.setOn(true)
        XCTAssertEqual(controller.effect, NightModeEffect(nightAudio: true, volume: 0.5, dimOpacity: 0.6))
        XCTAssertTrue(store.settings.isOn)
        XCTAssertEqual(makeController().settings.volumePercent, 50)
        XCTAssertTrue(makeController().settings.isOn)
    }

    func test_setSchedule_enabling_recordsNowAsApplied_andChangesNothing() {
        clock = date(day: 10, hour: 23)
        controller.setOn(true)
        controller.setSchedule(window)
        XCTAssertTrue(controller.settings.isOn)
        XCTAssertEqual(store.lastBoundaryApplied, clock)
        clock = date(day: 10, hour: 23, minute: 30)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
    }

    func test_evaluate_afterStart_turnsOn_andNotifiesObserver() {
        controller.setSchedule(window)
        var received: [NightModeEffect] = []
        let observation = controller.observeEffect { received.append($0) }
        clock = date(day: 10, hour: 22, minute: 1)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
        XCTAssertEqual(received, [controller.effect])
        XCTAssertEqual(store.lastBoundaryApplied, date(day: 10, hour: 22))
        controller.evaluate()
        XCTAssertEqual(received.count, 1)
        observation.cancel()
    }

    func test_manualOff_insideWindow_holdsUntilNextStart() {
        clock = date(day: 10, hour: 22, minute: 5)
        controller.setSchedule(window)
        clock = date(day: 10, hour: 22, minute: 10)
        controller.setOn(true)
        clock = date(day: 10, hour: 23)
        controller.setOn(false)
        clock = date(day: 11, hour: 6)
        controller.evaluate()
        XCTAssertFalse(controller.settings.isOn)
        clock = date(day: 11, hour: 22, minute: 1)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
    }

    func test_clockSetBackwards_doesNotStallSchedule() {
        controller.setSchedule(window)
        clock = date(day: 10, hour: 23)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
        // Clock set back a day: lastBoundaryApplied (10th 22:00) is now ahead.
        clock = date(day: 9, hour: 12)
        controller.evaluate()
        XCTAssertEqual(store.lastBoundaryApplied, clock)
        clock = date(day: 9, hour: 22, minute: 30)
        controller.setOn(false)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn, "The 22:00 boundary before the stored date must apply")
    }

    func test_timeZoneChange_evaluatesStoredTimesInNewZone() {
        controller.setSchedule(window)
        // Built in UTC, before the zone changes.
        let at1400 = date(day: 10, hour: 14)
        let at1300 = date(day: 10, hour: 13)
        let at2200 = date(day: 10, hour: 22)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        controller = makeController()
        // 22:00 Tokyo is 13:00 UTC: past at 14:00 UTC, though not 22:00 UTC.
        clock = at1400
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
        XCTAssertEqual(store.lastBoundaryApplied, at1300)
        XCTAssertEqual(controller.nextWake, at2200)
    }

    func test_manualOn_outsideWindow_holdsUntilNextBoundary() {
        controller.setSchedule(window)
        controller.setOn(true)
        clock = date(day: 10, hour: 18)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
        clock = date(day: 11, hour: 7, minute: 1)
        controller.evaluate()
        XCTAssertFalse(controller.settings.isOn, "The next boundary (turn off) applies")
    }

    func test_editingTimeWhileEnabled_changesNothingUntilNextBoundary() {
        clock = date(day: 10, hour: 21)
        controller.setSchedule(window)
        // 22:00 passes with no evaluation, then the time is edited to 22:05.
        clock = date(day: 10, hour: 22, minute: 10)
        var edited = window
        edited.turnOn = TimeOfDay(hour: 22, minute: 5)
        controller.setSchedule(edited)
        clock = date(day: 10, hour: 22, minute: 20)
        controller.evaluate()
        XCTAssertFalse(controller.settings.isOn, "The edit forgets boundaries before it")
        clock = date(day: 11, hour: 22, minute: 6)
        controller.evaluate()
        XCTAssertTrue(controller.settings.isOn)
    }

    func test_scheduleOff_keepsCurrentValue() {
        controller.setSchedule(window)
        controller.setOn(true)
        var disabled = window
        disabled.isEnabled = false
        controller.setSchedule(disabled)
        XCTAssertTrue(controller.settings.isOn)
        XCTAssertNil(controller.nextWake)
    }

    func test_observer_notCalled_forUnchangedEffect() {
        var calls = 0
        let observation = controller.observeEffect { _ in calls += 1 }
        controller.setVolumePercent(30)
        controller.setNightAudio(false)
        controller.setOn(true)
        XCTAssertEqual(calls, 1)
        controller.setOn(true)
        XCTAssertEqual(calls, 1)
        controller.setBrightnessPercent(80)
        XCTAssertEqual(calls, 2)
        observation.cancel()
        controller.setBrightnessPercent(50)
        XCTAssertEqual(calls, 2)
    }

    func test_observer_stopsWhenObservationIsReleased() {
        var calls = 0
        var observation: NightModeObservation? = controller.observeEffect { _ in calls += 1 }
        controller.setOn(true)
        XCTAssertEqual(calls, 1)
        observation = nil
        controller.setOn(false)
        XCTAssertEqual(calls, 1)
        _ = observation
    }

    func test_wake_isAtNextBoundary() {
        XCTAssertNil(controller.nextWake)
        controller.setSchedule(window)
        XCTAssertEqual(controller.nextWake, date(day: 10, hour: 22))
        clock = date(day: 10, hour: 22, minute: 1)
        controller.evaluate()
        XCTAssertEqual(controller.nextWake, date(day: 11, hour: 7))
    }
}
