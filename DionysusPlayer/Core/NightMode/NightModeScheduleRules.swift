import Foundation

/// The schedule's arithmetic, pure so tests can fix the calendar and the clock.
enum NightModeScheduleRules {
    /// The boundary to act on now, if any: the latest one after `lastApplied`
    /// and not after `now`. Several missed boundaries collapse to that one, as
    /// only the state the schedule would have left it in matters. A nil
    /// `lastApplied` means nothing to apply: turning the schedule on changes
    /// nothing until the next boundary.
    static func boundaryToApply(
        schedule: NightModeSchedule,
        lastApplied: Date?,
        now: Date,
        calendar: Calendar
    ) -> (date: Date, turnsOn: Bool)? {
        guard schedule.isEnabled, !schedule.neverTriggers, let lastApplied, lastApplied < now else { return nil }
        // Boundaries older than a few days can't be the latest, so a long
        // absence doesn't walk every day since.
        var cursor = max(lastApplied, now.addingTimeInterval(-3 * 24 * 3600))
        var latest: (date: Date, turnsOn: Bool)?
        while let next = boundary(after: cursor, schedule: schedule, calendar: calendar), next.date <= now {
            latest = next
            cursor = next.date
        }
        return latest
    }

    /// The nearest boundary, on or off, after `now`; nil when the schedule is
    /// off or its two times are equal.
    static func nextBoundary(after now: Date, schedule: NightModeSchedule, calendar: Calendar) -> Date? {
        guard schedule.isEnabled, !schedule.neverTriggers else { return nil }
        return boundary(after: now, schedule: schedule, calendar: calendar)?.date
    }

    /// `.nextTime` moves a time that falls in a daylight-saving gap forward
    /// rather than skipping the day.
    private static func boundary(
        after date: Date,
        schedule: NightModeSchedule,
        calendar: Calendar
    ) -> (date: Date, turnsOn: Bool)? {
        func next(_ time: TimeOfDay) -> Date? {
            calendar.nextDate(
                after: date,
                matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                matchingPolicy: .nextTime
            )
        }
        switch (next(schedule.turnOn), next(schedule.turnOff)) {
        case let (on?, off?): return on < off ? (on, true) : (off, false)
        case let (on?, nil): return (on, true)
        case let (nil, off?): return (off, false)
        case (nil, nil): return nil
        }
    }
}
