import Foundation

/// The Apple TV's schedule times: − and + move a time 15 minutes, wrapping
/// past midnight, so neither is ever inert (Benjamin, 2026-11-16). A time off
/// the quarter-hour grid (another build's, or iOS's picker on a store this
/// device shares) steps to the next or previous quarter hour: + from 22:07
/// is 22:15, − is 22:00.
enum NightModeTimeStep {
    static let minutes = 15
    private static let day = 24 * 60

    static func step(_ time: TimeOfDay, forward: Bool) -> TimeOfDay {
        let now = time.minutesSinceMidnight
        let floor = now / minutes * minutes
        let next: Int
        if forward {
            next = floor + minutes
        } else {
            next = now == floor ? floor - minutes : floor
        }
        return TimeOfDay(minutesSinceMidnight: (next % day + day) % day)
    }
}
