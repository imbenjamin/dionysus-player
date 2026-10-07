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
    /// open; with the transport up it stays on screen without focus.
    static func nextUpHasFocus(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.nextUpSecondsRemaining != nil && state.chrome == .hidden && state.panel == nil && state.scrub == nil
    }

    /// Always with the transport up; with it hidden, until Menu hides it.
    static func skipButtonVisible(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        guard let segment = context.skipSegment else { return false }
        return state.chrome == .transport || state.hiddenSkipSegmentID != segment.id
    }

    /// Whether Select means Skip: the button shows and focus isn't on an
    /// icon, in the panel or in a scrub. The button is drawn focused then.
    static func selectSkips(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        skipButtonVisible(state, context: context) && state.panel == nil && state.scrub == nil
            && state.transportFocus == .scrubber
    }

    static func playNext(_ state: inout TVPlayerInputState) -> [TVPlayerCommand] {
        guard !state.hasRequestedAdvance else { return [] }
        state.hasRequestedAdvance = true
        return [.playNext]
    }
}
