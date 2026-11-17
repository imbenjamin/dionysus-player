import Foundation

/// The schedule's times as a picker's `Date` and as text: the player's
/// summary, iOS's `DatePicker`s and the Apple TV's time rows.
/// 12- or 24-hour follows the locale.
///
/// Every `Date` here is a time on a fixed day in GMT, so no time zone or
/// daylight-saving gap moves it; a picker showing one is set to GMT too.
enum NightModeTimeFormat {
    static let timeZone = TimeZone(secondsFromGMT: 0)!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(for time: TimeOfDay) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(time.minutesSinceMidnight * 60))
    }

    static func time(from date: Date) -> TimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    static func usesTwentyFourHourClock(_ locale: Locale) -> Bool {
        locale.hourCycle == .zeroToTwentyThree || locale.hourCycle == .oneToTwentyFour
    }

    /// "07:00" on a 24-hour clock (two-digit hours, as the spec writes it;
    /// `.shortened` alone gave "7:00" in en_GB), "7:00 AM" on a 12-hour one.
    static func text(_ time: TimeOfDay, locale: Locale) -> String {
        let twentyFourHour = usesTwentyFourHourClock(locale)
        return format(
            time,
            Date.FormatStyle()
                .hour(twentyFourHour ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated))
                .minute(.twoDigits),
            locale: locale
        )
    }

    private static func format(_ time: TimeOfDay, _ style: Date.FormatStyle, locale: Locale) -> String {
        var style = style
        style.locale = locale
        style.timeZone = timeZone
        return date(for: time).formatted(style)
    }
}
