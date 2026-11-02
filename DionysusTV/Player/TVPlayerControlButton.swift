import SwiftUI

/// A player control the focus engine can reach, for the accessible
/// transport (M5). Drawn by `label` from the focus engine's own focus,
/// read the way `TVSidebarRowStyle` reads it, so it looks exactly like the
/// model-drawn control it stands in for.
struct TVPlayerControlButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ isFocused: Bool) -> Label

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(Style(label: label))
    }

    private struct Style: ButtonStyle {
        let label: (Bool) -> Label
        func makeBody(configuration: Configuration) -> some View { Face(label: label) }
    }

    private struct Face: View {
        let label: (Bool) -> Label
        @Environment(\.isFocused) private var isFocused
        var body: some View { label(isFocused) }
    }
}

/// The accessible transport's extra buttons (M5), left to right before the
/// icons: back 10s, Play/Pause, forward 10s, Info.
enum TVAccessibleTransportButton: CaseIterable {
    case back, playPause, forward, info

    var id: String {
        switch self {
        case .back: "back"
        case .playPause: "playPause"
        case .forward: "forward"
        case .info: "info"
        }
    }

    func systemImage(isPlaying: Bool) -> String {
        switch self {
        case .back: "gobackward.10"
        case .playPause: isPlaying ? "pause.fill" : "play.fill"
        case .forward: "goforward.10"
        case .info: "info.circle"
        }
    }

    /// Worded by what a press does, as iOS's controls are.
    func label(isPlaying: Bool) -> String {
        switch self {
        case .back: String(localized: "Back 10 seconds")
        case .playPause: isPlaying ? String(localized: "Pause") : String(localized: "Play")
        case .forward: String(localized: "Forward 10 seconds")
        case .info: String(localized: "Info")
        }
    }

    var control: TVPlayerControl {
        switch self {
        case .back: .skip(.left)
        case .playPause: .playPause
        case .forward: .skip(.right)
        case .info: .openPanel(.info)
        }
    }
}
