import Foundation
import Observation
import UIKit

/// What set off a change to `NightModeController.effect`. The player eases a
/// scheduled change in and says so (`PlayerViewModel.applyNightMode`); a
/// change by hand applies at once, since the person making it is watching.
enum NightModeChangeCause: Equatable, Sendable {
    /// A switch, a level or a setting changed by hand.
    case manual
    /// A schedule boundary passed, turning Night Mode on or off.
    case schedule(turnsOn: Bool)
}

/// One change to `NightModeController.effect`, as its observers receive it.
struct NightModeChange: Equatable, Sendable {
    var effect: NightModeEffect
    var cause: NightModeChangeCause
}

/// A subscription to `NightModeController.effect`; it stops on `cancel()` or
/// when released.
@MainActor
final class NightModeObservation {
    fileprivate var handler: (@MainActor (NightModeChange) -> Void)?

    fileprivate init(handler: @escaping @MainActor (NightModeChange) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
    }
}

/// The one place Night Mode's state lives: the settings, the schedule's
/// boundaries and the wake that acts on them. The player and the settings
/// screens bind to it.
///
/// A flip by hand lasts until the next schedule boundary: `setOn` never
/// touches `lastBoundaryApplied`, so the schedule only acts on a boundary
/// that passes after the flip.
@Observable
@MainActor
final class NightModeController {
    static let shared = NightModeController()

    private(set) var settings: NightModeSettings
    var effect: NightModeEffect { settings.effect }

    /// When the wake will next run; nil with the schedule off.
    private(set) var nextWake: Date?

    @ObservationIgnored private let store: NightModeStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let schedulesWakes: Bool
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var observations: [WeakObservation] = []

    private struct WeakObservation {
        weak var value: NightModeObservation?
    }

    init(
        store: NightModeStore = NightModeStore(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        schedulesWakes: Bool = true
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.schedulesWakes = schedulesWakes
        self.settings = store.settings
        evaluate()
        if schedulesWakes {
            for name in [UIApplication.willEnterForegroundNotification, UIApplication.significantTimeChangeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                }
            }
        }
    }

    func setOn(_ on: Bool) {
        update { $0.isOn = on }
    }

    func setNightAudio(_ on: Bool) {
        update { $0.nightAudio = on }
    }

    func setVolumePercent(_ percent: Int) {
        update { $0.volumePercent = NightModeLevel.clamped(percent) }
    }

    func setBrightnessPercent(_ percent: Int) {
        update { $0.brightnessPercent = NightModeLevel.clamped(percent) }
    }

    /// Enabling the schedule or moving a time starts it from now: it changes
    /// nothing until the next boundary. Disabling leaves `isOn` as it is.
    func setSchedule(_ schedule: NightModeSchedule) {
        let old = settings.schedule
        update { $0.schedule = schedule }
        if schedule.isEnabled,
           !old.isEnabled || old.turnOn != schedule.turnOn || old.turnOff != schedule.turnOff {
            store.lastBoundaryApplied = now()
        }
        scheduleWake()
    }

    /// Acts on the schedule boundary that has passed since the last one
    /// applied, if any, and sets the wake for the next.
    func evaluate() {
        // A clock set backwards must not leave the schedule waiting on a
        // boundary applied "in the future".
        if let last = store.lastBoundaryApplied, last > now() {
            store.lastBoundaryApplied = now()
        }
        if let boundary = NightModeScheduleRules.boundaryToApply(
            schedule: settings.schedule,
            lastApplied: store.lastBoundaryApplied,
            now: now(),
            calendar: calendar
        ) {
            store.lastBoundaryApplied = boundary.date
            applyScheduledBoundary(turnsOn: boundary.turnsOn)
        }
        scheduleWake()
    }

    /// What a schedule boundary does: switches Night Mode, as the schedule's
    /// change. `evaluate()` calls it when a boundary passes; under the UI-test
    /// harness, `-UITestNightModeScheduledSwitchAfter` stands in for one, since
    /// a journey can't wait for a time of day.
    func applyScheduledBoundary(turnsOn: Bool) {
        update(cause: .schedule(turnsOn: turnsOn)) { $0.isOn = turnsOn }
    }

    /// Calls `handler` whenever `effect` changes, with what changed it, not on
    /// a write that leaves it as it was (a level edited while off).
    func observeEffect(_ handler: @escaping @MainActor (NightModeChange) -> Void) -> NightModeObservation {
        let observation = NightModeObservation(handler: handler)
        observations.removeAll { $0.value == nil }
        observations.append(WeakObservation(value: observation))
        return observation
    }

    private func update(cause: NightModeChangeCause = .manual, _ change: (inout NightModeSettings) -> Void) {
        let before = settings.effect
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        store.settings = changed
        let after = changed.effect
        guard after != before else { return }
        for entry in observations {
            entry.value?.handler?(NightModeChange(effect: after, cause: cause))
        }
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        nextWake = NightModeScheduleRules.nextBoundary(after: now(), schedule: settings.schedule, calendar: calendar)
        guard schedulesWakes, let wake = nextWake else { return }
        let delay = max(wake.timeIntervalSince(now()), 0)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
