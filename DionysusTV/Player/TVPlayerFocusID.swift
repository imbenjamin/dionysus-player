/// The focused item as a fixed id. The overlay draws focus from the state
/// directly; this exists for the UI tests, which can't see focus in a
/// player that doesn't use the focus engine (`A11yID.TV.Player.focus`).
enum TVPlayerFocusID {
    static func describe(_ state: TVPlayerInputState, context: TVPlayerContext) -> String {
        if let panel = state.panel {
            switch panel.focus {
            case .tabs: return "tab.\(panel.tab.id)"
            case .content(let index): return "content.\(panel.tab.id).\(index)"
            }
        }
        if TVPlayerInputModel.nextUpHasFocus(state, context: context) {
            return state.nextUpFocus == .playNow ? "nextUp.playNow" : "nextUp.close"
        }
        if state.chrome == .transport, case .icon(let icon) = state.transportFocus { return "icon.\(icon.id)" }
        if TVPlayerInputModel.selectSkips(state, context: context) { return "skip" }
        return state.chrome == .transport ? "scrubber" : "none"
    }
}
