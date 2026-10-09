import Foundation

extension TVPlayerInputModel {
    /// The accessible transport's controls (M5). Each reuses what the
    /// remote's own path does, so both modes act the same. Only showing the
    /// controls or opening the panel brings the controls up: Left and Right
    /// on the hidden layer skip and leave them hidden (Benjamin, 2026-10-08).
    static func reduceControl(
        _ control: TVPlayerControl, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        switch control {
        case .playPause:
            return togglePlayPause(&state, context: context)
        case .skip(let direction):
            let commands = skip(direction, context: context)
            if !commands.isEmpty { flash(direction == .left ? .skipBack : .skipForward, &state) }
            return commands
        case .openPanel(let tab):
            guard availableTabs(context).contains(tab) else { return [] }
            openPanel(tab, focus: .tabs, &state, now: now)
            return []
        case .toggleStats:
            if context.statsButtonEnabled { state.isStatsOn.toggle() }
            return []
        case .panelRow(let index):
            guard let panel = state.panel else { return [] }
            let (commands, closes) = activateRow(panel.tab, index, context)
            if closes { state.panel = nil }
            return commands
        case .skipSegment:
            return context.skipSegment.map { [.skipSegment(id: $0.id)] } ?? []
        case .nextUp(let button):
            guard context.nextUpSecondsRemaining != nil else { return [] }
            return button == .playNow ? playNext(&state) : [.dismissNextUp]
        case .showControls:
            // The layer puts focus on Play/Pause.
            state.chrome = .transport
            return []
        }
    }

    /// Menu in the accessible transport: closes the panel, then hides the
    /// controls, then leaves (Benjamin, 2026-10-08). Nothing hides them by
    /// itself, so watching without them is the person's choice.
    static func accessibleMenu(_ state: inout TVPlayerInputState) -> [TVPlayerCommand] {
        if state.panel != nil {
            state.panel = nil
            return []
        }
        if state.chrome == .transport {
            state.chrome = .hidden
            return []
        }
        return [.close]
    }
}
