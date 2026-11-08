import SwiftUI

/// Whether VoiceOver is running, for a view that changes under it: the
/// system's `accessibilityVoiceOverEnabled`, or the UI-test harness standing
/// in for it (`-UITestSimulateVoiceOver`).
///
/// A view reads this rather than the environment value directly. That value
/// is read-only, and XCUITest can't turn VoiceOver on, so without a stand-in
/// the player's controls button, Home's Refresh button and the hero's
/// announcements were reached by no test (TQ-12).
@propertyWrapper
struct VoiceOverEnabled: DynamicProperty {
    @Environment(\.accessibilityVoiceOverEnabled) private var systemValue

    var wrappedValue: Bool {
        #if DEBUG
        if UITestHarness.simulatesVoiceOver { return true }
        #endif
        return systemValue
    }
}

/// Posts a VoiceOver announcement. Under the harness's simulated VoiceOver it
/// also records the message in `UITestAnnouncementLog`, since nothing is
/// spoken and XCUITest can't hear an announcement anyway.
@MainActor
enum VoiceOverAnnouncement {
    static func post(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
        #if DEBUG
        if UITestHarness.simulatesVoiceOver {
            UITestAnnouncementLog.shared.last = message
        }
        #endif
    }
}

#if DEBUG
/// The last announcement `VoiceOverAnnouncement` posted under simulated
/// VoiceOver, shown by `UITestAnnouncementProbe` for a test to read.
@MainActor
@Observable
final class UITestAnnouncementLog {
    static let shared = UITestAnnouncementLog()
    var last: String?
}

/// A one-point text carrying the last announcement as its label, mounted only
/// under simulated VoiceOver, over the main app (`MainTabView`).
struct UITestAnnouncementProbe: View {
    var body: some View {
        if UITestHarness.simulatesVoiceOver {
            Text(verbatim: UITestAnnouncementLog.shared.last ?? "")
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier(A11yID.UITest.lastAnnouncement)
        }
    }
}
#endif
