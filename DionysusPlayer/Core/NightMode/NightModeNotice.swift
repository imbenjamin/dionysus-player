import Foundation

/// What the player says when the schedule switches Night Mode while a title
/// plays (Benjamin, 2026-11-17): the dimming and the volume ease over
/// `PlayerViewModel.nightModeTransitionDuration`, and this says why. A
/// change by hand says nothing, since the person making it is watching.
enum NightModeNotice: Equatable, Sendable {
    case starting
    case ending

    init(turnsOn: Bool) {
        self = turnsOn ? .starting : .ending
    }

    var message: String {
        switch self {
        case .starting: String(localized: "Night Mode starting as scheduled")
        case .ending: String(localized: "Night Mode ending as scheduled")
        }
    }

    var systemImage: String {
        switch self {
        case .starting: "moon.fill"
        case .ending: "sun.max.fill"
        }
    }
}
