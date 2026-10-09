import Foundation

/// When the player uses the accessible transport (M5): whenever VoiceOver
/// or Switch Control runs, both of which need focusable controls, or the
/// UI-test harness forces it (XCUITest can't run VoiceOver).
enum TVAccessibleTransport {
    static func isOn(voiceOver: Bool, switchControl: Bool, forced: Bool) -> Bool {
        voiceOver || switchControl || forced
    }
}

/// What the accessible transport says aloud. One short phrase per action;
/// the mid-screen flashes stay as they are.
enum TVPlayerAnnouncement {
    static func text(for kind: TVPlayerInputState.Flash.Kind) -> String {
        switch kind {
        case .play: String(localized: "Playing")
        case .pause: String(localized: "Paused")
        case .skipBack: String(localized: "Back 10 seconds")
        case .skipForward: String(localized: "Forward 10 seconds")
        }
    }

    /// "Audio, French" for a track switch among `commands`, else `nil`.
    static func trackChosen(_ commands: [TVPlayerCommand], context: TVPlayerContext) -> String? {
        for command in commands {
            switch command {
            case .selectAudio(let id):
                guard let index = context.audioTrackIDs.firstIndex(of: id),
                      context.audioTrackTitles.indices.contains(index) else { continue }
                return String(localized: "Audio, \(context.audioTrackTitles[index])")
            case .selectSubtitle(nil):
                return String(localized: "Subtitles, Off")
            case .selectSubtitle(let id?):
                guard let index = context.subtitleTrackIDs.firstIndex(of: id),
                      context.subtitleTrackTitles.indices.contains(index) else { continue }
                return String(localized: "Subtitles, \(context.subtitleTrackTitles[index])")
            default:
                continue
            }
        }
        return nil
    }

    static func skipAvailable(_ title: String) -> String { String(localized: "\(title) available") }
    static func nextUp(_ title: String) -> String { String(localized: "Up next: \(title)") }
}
