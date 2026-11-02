import Foundation

/// The audio offset's one range and step, read by the store, the controller
/// and both UIs. Positive delays audio (AetherEngine's `audioDelaySeconds`).
enum AudioOffset {
    static let range: ClosedRange<Int> = -500...500
    static let step = 10

    /// Clamped to `range` and rounded to the nearest `step`, half away from zero.
    static func normalized(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, range.lowerBound), range.upperBound)
        let steps = (Double(clamped) / Double(step)).rounded(.toNearestOrAwayFromZero)
        return Int(steps) * step
    }

    static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }
}

/// Where the player's Audio panel writes: the playing title's own offset, or
/// the global one (spec, "Decisions").
enum AudioOffsetScope: Equatable {
    case thisTitle, allTitles
}

/// The offset as shown and as spoken, on both platforms.
enum AudioOffsetFormat {
    /// "+40 ms", "−30 ms" (U+2212), "0 ms".
    static func value(_ milliseconds: Int) -> String {
        let magnitude = abs(milliseconds).formatted()
        let sign = milliseconds > 0 ? "+" : milliseconds < 0 ? "\u{2212}" : ""
        return String(localized: "\(sign)\(magnitude) ms", comment: "Audio offset value, e.g. +40 ms")
    }

    static func hint(_ milliseconds: Int) -> String {
        if milliseconds > 0 { return String(localized: "Audio later") }
        if milliseconds < 0 { return String(localized: "Audio earlier") }
        return String(localized: "In sync")
    }

    static func spoken(_ milliseconds: Int) -> String {
        let magnitude = abs(milliseconds).formatted()
        return String(localized: "\(magnitude) milliseconds, \(hint(milliseconds).lowercased())")
    }
}
