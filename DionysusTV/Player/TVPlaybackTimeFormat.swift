import Foundation

/// The transport's elapsed and remaining times: "12:34", or "2:02:05" past an
/// hour. Anything non-finite or negative reads "0:00", which is what the
/// engine reports before a duration is known.
enum TVPlaybackTimeFormat {
    static func string(_ time: TimeInterval) -> String {
        let t = time.isFinite ? max(0, Int(time)) : 0
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// `string`'s spoken form, "12 minutes, 30 seconds", as iOS's scrubber
    /// reads it (`PlayerControlsOverlay.spokenTime`).
    static func spoken(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "0 seconds") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        guard let text = formatter.string(from: seconds.rounded(.down)), !text.isEmpty else {
            return String(localized: "0 seconds")
        }
        return text
    }

    /// The scrubber's accessibility value: "12 minutes, 30 seconds of 1 hour, 52 minutes".
    static func spokenPosition(_ seconds: TimeInterval, of duration: TimeInterval) -> String {
        String(localized: "\(spoken(seconds)) of \(spoken(duration))")
    }
}
