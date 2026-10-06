/// The focused item as a fixed id. The overlay draws focus from the state
/// directly; this exists for the UI tests, which can't see focus in a
/// player that doesn't use the focus engine (`A11yID.TV.Player.focus`).
enum TVPlayerFocusID {
    static func describe(_ state: TVPlayerInputState, context: TVPlayerContext) -> String {
        if state.chrome == .transport, case .icon(let icon) = state.transportFocus { return "icon.\(icon.id)" }
        return state.chrome == .transport ? "scrubber" : "none"
    }
}
