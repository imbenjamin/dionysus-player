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
}
