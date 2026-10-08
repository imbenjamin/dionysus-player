import Foundation

extension TVPlayerInputModel {
    /// Skip Intro/Credits and the Next Up card. `nil` for intents they
    /// leave to the transport.
    static func reduceOverlays(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext
    ) -> [TVPlayerCommand]? {
        if nextUpHasFocus(state, context: context) {
            switch intent {
            case .select:
                return state.nextUpFocus == .playNow ? playNext(&state) : [.dismissNextUp]
            case .arrow(let direction):
                state.nextUpFocus = direction == .left ? .playNow : .close
                return []
            case .menu:
                // Up over the transport, Menu leaves the card as it leaves the
                // icons; alone on screen, it means Close.
                guard state.chrome == .hidden else {
                    state.transportFocus = .scrubber
                    return []
                }
                return [.dismissNextUp]
            default:
                return nil
            }
        }
        if let segment = context.skipSegment, selectSkips(state, context: context) {
            switch intent {
            case .select:
                return [.skipSegment(id: segment.id)]
            case .menu where state.chrome == .hidden:
                state.hiddenSkipSegmentID = segment.id
                return []
            default:
                return nil
            }
        }
        return nil
    }

    /// The card has focus while the transport is hidden and nothing else is
    /// open; with the transport up, once Up from the icons reaches it.
    /// Whether the stats panel is drawn: its toggle and its setting on, and
    /// neither the tabs panel nor the Next Up card up, since they share the
    /// right half of the screen (Benjamin, 2026-10-08). The toggle stays on
    /// underneath, so the panel returns when they go.
    static func statsPanelShows(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        state.isStatsOn && context.statsButtonEnabled && state.panel == nil && context.nextUpSecondsRemaining == nil
    }

    static func nextUpHasFocus(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        guard context.nextUpSecondsRemaining != nil, state.panel == nil, state.scrub == nil else { return false }
        return state.chrome == .hidden || state.transportFocus == .nextUp
    }

    /// The bottom-right slot's stop above the icon row, if anything shows
    /// there. Next Up and Skip never show together.
    static func slotFocus(_ state: TVPlayerInputState, context: TVPlayerContext) -> TVPlayerInputState.TransportFocus? {
        if context.nextUpSecondsRemaining != nil { return .nextUp }
        if skipButtonVisible(state, context: context) { return .skip }
        return nil
    }

    /// Always with the transport up; with it hidden, until Menu hides it.
    static func skipButtonVisible(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        guard let segment = context.skipSegment else { return false }
        return state.chrome == .transport || state.hiddenSkipSegmentID != segment.id
    }

    /// Whether Select means Skip, and so the button is drawn focused: with
    /// the transport hidden whenever it shows; with the transport up only
    /// once focus is on it, above the icons (Benjamin, 2026-10-07). Never in
    /// the panel or a scrub.
    static func selectSkips(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        guard skipButtonVisible(state, context: context), state.panel == nil, state.scrub == nil else { return false }
        return state.chrome == .hidden || state.transportFocus == .skip
    }

    static func playNext(_ state: inout TVPlayerInputState) -> [TVPlayerCommand] {
        guard !state.hasRequestedAdvance else { return [] }
        state.hasRequestedAdvance = true
        return [.playNext]
    }
}
