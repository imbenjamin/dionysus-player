import SwiftUI

extension TVPlayerIcon {
    var systemImage: String {
        switch self {
        case .chapters: "list.bullet"
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        case .stats: "chart.bar.xaxis"
        }
    }

    /// Stats is worded as iOS's stats button is (`PlayerControlsOverlay`),
    /// by what a press would do (Benjamin, 2026-10-07).
    func label(isOn: Bool) -> String {
        switch self {
        case .chapters: String(localized: "Chapters")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        case .stats: isOn ? String(localized: "Hide playback stats") : String(localized: "Show playback stats")
        }
    }
}

/// One of the transport's icons (prototype screen 12). Drawn focused from
/// the model's state: the player doesn't use the focus engine.
struct TVPlayerIconButton: View {
    let icon: TVPlayerIcon
    let isFocused: Bool
    /// Stats' panel is showing.
    var isOn = false

    var body: some View {
        TVPlayerIconFace(systemImage: icon.systemImage, isFocused: isFocused, isOn: isOn)
            .accessibilityElement()
            .accessibilityLabel(icon.label(isOn: isOn))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(A11yID.TV.Player.icon(icon.id))
    }
}

/// The icon's look for a given focus; shared by the remote's mode (focus
/// from the model) and the accessible transport (focus from the engine).
struct TVPlayerIconFace: View {
    let systemImage: String
    let isFocused: Bool
    var isOn = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: 84, height: 84)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(isOn ? 0.4 : 0.18)))
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

extension TVPlayerIcon {
    /// The panel tab an icon opens; Stats opens none, and is never asked.
    var panelTab: TVPanelTab {
        switch self {
        case .chapters: .chapters
        case .audio: .audio
        case .subtitles: .subtitles
        case .stats: .info
        }
    }
}
