import Foundation

/// What VoiceOver says on the way in that the screen's text alone wouldn't.
enum TVOnboardingSpeech {
    /// A Quick Connect code a digit at a time, the way it's typed in:
    /// read whole, "123456" is a number in the hundreds of thousands.
    static func spokenCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    /// Said once, when discovery's list stops being empty: the first server
    /// takes focus, but nothing else says the scan found anything. Servers
    /// that arrive after it are read as focus reaches them.
    static func foundServersAnnouncement(count: Int, previousCount: Int) -> String? {
        guard previousCount == 0, count > 0 else { return nil }
        return count == 1 ? String(localized: "Found a server") : String(localized: "Found \(count) servers")
    }

    /// Said when a scan ends with nothing found: "No servers found." can't
    /// take focus, so it's never read otherwise.
    static func scanEndedAnnouncement(wasScanning: Bool, isScanning: Bool, serverCount: Int) -> String? {
        guard wasScanning, !isScanning, serverCount == 0 else { return nil }
        return String(localized: "No servers found.")
    }
}
