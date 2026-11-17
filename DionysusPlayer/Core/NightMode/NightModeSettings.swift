import Foundation

/// A wall-clock time with no date, for the Night Mode schedule.
struct TimeOfDay: Equatable, Sendable {
    var hour: Int
    var minute: Int

    var minutesSinceMidnight: Int { hour * 60 + minute }

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init(minutesSinceMidnight minutes: Int) {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        self.init(hour: clamped / 60, minute: clamped % 60)
    }
}

/// When Night Mode turns itself on and off. The two times may straddle
/// midnight; equal times describe a window that never opens.
struct NightModeSchedule: Equatable, Sendable {
    var isEnabled: Bool
    var turnOn: TimeOfDay
    var turnOff: TimeOfDay

    var neverTriggers: Bool { turnOn == turnOff }
}

/// The step and range of the Volume Limit and Brightness sliders.
enum NightModeLevel {
    static let range = 0...100
    static let step = 5

    /// Rounds to the nearest step, then clamps to the range.
    static func clamped(_ percent: Int) -> Int {
        let snapped = Int((Double(percent) / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// What playback applies while Night Mode is on: `.none` when it is off.
struct NightModeEffect: Equatable, Sendable {
    var nightAudio: Bool
    /// The player volume's ceiling, 0...1.
    var volume: Float
    /// The black overlay's opacity, 0 (full brightness) to 1.
    var dimOpacity: Double

    static let none = NightModeEffect(nightAudio: false, volume: 1, dimOpacity: 0)
}

struct NightModeSettings: Equatable, Sendable {
    var isOn: Bool
    var nightAudio: Bool
    var volumePercent: Int
    var brightnessPercent: Int
    var schedule: NightModeSchedule

    static let defaults = NightModeSettings(
        isOn: false,
        nightAudio: true,
        volumePercent: 100,
        brightnessPercent: 100,
        schedule: NightModeSchedule(
            isEnabled: false,
            turnOn: TimeOfDay(hour: 22, minute: 0),
            turnOff: TimeOfDay(hour: 7, minute: 0)
        )
    )

    var effect: NightModeEffect {
        guard isOn else { return .none }
        return NightModeEffect(
            nightAudio: nightAudio,
            volume: Float(volumePercent) / 100,
            dimOpacity: 1 - Double(brightnessPercent) / 100
        )
    }
}
