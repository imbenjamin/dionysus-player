import UIKit

/// A keyboard key the player acts on that has no remote press of its own. The
/// space bar is Play/Pause, as in the system player; a Bluetooth keyboard and
/// the Simulator's on-screen remote both send it as a keyboard press (type
/// 2044, HID usage 0x2C) rather than `.playPause`. Arrows and Escape arrive as
/// remote presses as well, so they are handled there, once.
enum TVKeyboardCommand: Equatable {
    case playPause

    init?(keyCode: UIKeyboardHIDUsage) {
        switch keyCode {
        case .keyboardSpacebar: self = .playPause
        default: return nil
        }
    }
}
