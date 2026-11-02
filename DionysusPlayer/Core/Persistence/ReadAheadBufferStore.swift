import Foundation

/// Profile → Playback → Advanced → Read-Ahead Buffer, in seconds. Both apps'
/// `@AppStorage` reads declare `ReadAheadBufferStore.defaultSeconds`.
let readAheadBufferSecondsStorageKey = "readAheadBufferSeconds"

/// How far ahead the player loads a file it plays directly
/// (`LoadOptions.forwardBufferSegments`). A direct-play remux has one fixed
/// bitrate, so this is its only cushion against a slow link: AetherEngine's
/// own ~40 s ran dry on a 4K remux over powerline and Wi-Fi (Benjamin,
/// 2026-10-21). Five minutes by default, in line with players for local
/// libraries; 30 s to 10 min in 30 s steps. Ignored on a server transcode,
/// where AVPlayer buffers against the server itself.
enum ReadAheadBufferStore {
    static let defaultSeconds = 300
    static let options = Array(stride(from: 30, through: 600, by: 30))

    /// AetherEngine's loopback segments run about 4 s.
    private static let secondsPerSegment = 4.0

    /// The stored value on the nearest step inside the range, or the default.
    static func seconds(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: readAheadBufferSecondsStorageKey) != nil else { return defaultSeconds }
        let stored = defaults.integer(forKey: readAheadBufferSecondsStorageKey)
        return options.min { abs($0 - stored) < abs($1 - stored) } ?? defaultSeconds
    }

    /// A part segment rounds up, so the window never falls short.
    static func segments(forSeconds seconds: Int) -> Int {
        Int((Double(seconds) / secondsPerSegment).rounded(.up))
    }

    /// "30 sec", "5 min", "5 min 30 sec". Written out rather than from
    /// `DateComponentsFormatter`, whose short style says "secs" in some
    /// regions and "sec" in others, so the two apps disagreed.
    static func displayName(seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return String(localized: "\(rest) sec") }
        if rest == 0 { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes) min \(rest) sec")
    }

    /// "5 minutes, 30 seconds".
    static func accessibilityLabel(seconds: Int) -> String {
        format(seconds, style: .full)
    }

    private static func format(_ seconds: Int, style: DateComponentsFormatter.UnitsStyle) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = style
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }
}
