import Foundation

/// The panel's Night tab (Benjamin, 2026-11-16): Night Mode and Night Audio,
/// then Volume Limit and Brightness, each a row of `[0%] [−] value [+]
/// [100%]`. Focus stops are numbered as `TVNightPanelRow.all` lists them.
extension TVPlayerInputModel {
    static func nightRow(at index: Int) -> TVNightPanelRow? {
        TVNightPanelRow.all.indices.contains(index) ? TVNightPanelRow.all[index] : nil
    }

    static func nightIndex(of row: TVNightPanelRow) -> Int {
        TVNightPanelRow.all.firstIndex(of: row) ?? 0
    }

    /// Entering a level from a switch lands on −: both levels start at 100%,
    /// where + and 100% do nothing, and turning one down is what Night Mode
    /// is for.
    static let nightLevelEntry = TVNightLevelControl.decrease

    // MARK: Moving

    /// Up from a level keeps the control (Brightness's + to Volume's +);
    /// from the first level it's Night Audio, from Night Mode the tabs.
    static func nightUp(from index: Int) -> TVPlayerInputState.Panel.Focus {
        switch nightRow(at: index) {
        case .nightMode, nil: return .tabs
        case .nightAudio: return .content(nightIndex(of: .nightMode))
        case .level(.volume, _): return .content(nightIndex(of: .nightAudio))
        case .level(.brightness, let control): return .content(nightIndex(of: .level(.volume, control)))
        }
    }

    /// Down keeps a level's control into the next level, and stops at the
    /// last row.
    static func nightDown(from index: Int) -> Int {
        switch nightRow(at: index) {
        case .nightMode: return nightIndex(of: .nightAudio)
        case .nightAudio: return nightIndex(of: .level(.volume, nightLevelEntry))
        case .level(.volume, let control): return nightIndex(of: .level(.brightness, control))
        case .level(.brightness, _), nil: return index
        }
    }

    /// Left and Right move among a level's four controls, without wrapping;
    /// the switches ignore them.
    static func nightArrow(_ direction: TVDirection, from index: Int) -> Int {
        guard case .level(let level, let control) = nightRow(at: index) else { return index }
        let controls = TVNightLevelControl.allCases
        let position = controls.firstIndex(of: control)! + direction.step
        guard controls.indices.contains(position) else { return index }
        return nightIndex(of: .level(level, controls[position]))
    }

    // MARK: Pressing

    /// What Select does on a stop. A control that would do nothing (− and
    /// 0% at 0%, + and 100% at 100%) stays a stop but is inert, so focus
    /// never jumps away as a level reaches its end.
    static func nightSelect(at index: Int, _ context: TVPlayerContext) -> [TVPlayerCommand] {
        switch nightRow(at: index) {
        case .nightMode: [.setNightMode(!context.night.isOn)]
        case .nightAudio: [.setNightAudio(!context.night.nightAudio)]
        case .level(let level, let control): nightPress(control, of: level, context)
        case nil: []
        }
    }

    static func nightPercent(_ level: TVNightLevel, _ context: TVPlayerContext) -> Int {
        level == .volume ? context.night.volumePercent : context.night.brightnessPercent
    }

    static func nightControlIsInert(_ control: TVNightLevelControl, percent: Int) -> Bool {
        let range = NightModeLevel.range
        switch control {
        case .min, .decrease: return percent <= range.lowerBound
        case .increase, .max: return percent >= range.upperBound
        }
    }

    static func nightPress(_ control: TVNightLevelControl, of level: TVNightLevel, _ context: TVPlayerContext) -> [TVPlayerCommand] {
        guard !nightControlIsInert(control, percent: nightPercent(level, context)) else { return [] }
        let range = NightModeLevel.range
        switch (level, control) {
        case (.volume, .min): return [.setVolume(range.lowerBound)]
        case (.volume, .decrease): return [.stepVolume(-NightModeLevel.step)]
        case (.volume, .increase): return [.stepVolume(NightModeLevel.step)]
        case (.volume, .max): return [.setVolume(range.upperBound)]
        case (.brightness, .min): return [.setBrightness(range.lowerBound)]
        case (.brightness, .decrease): return [.stepBrightness(-NightModeLevel.step)]
        case (.brightness, .increase): return [.stepBrightness(NightModeLevel.step)]
        case (.brightness, .max): return [.setBrightness(range.upperBound)]
        }
    }

    /// The accessible transport's swipe on a level row (one adjustable
    /// element, any of its stops' indices): a 5% step.
    static func nightAdjust(_ direction: TVDirection, at index: Int, _ context: TVPlayerContext) -> [TVPlayerCommand] {
        guard case .level(let level, _) = nightRow(at: index) else { return [] }
        return nightPress(direction == .right ? .increase : .decrease, of: level, context)
    }

    // MARK: Holding Select

    /// The level's − or + under the panel's focus, if that's where it is.
    static func nightHeldStep(_ state: TVPlayerInputState) -> (TVNightLevel, TVNightLevelControl)? {
        guard let panel = state.panel, panel.tab == .night, case .content(let index) = panel.focus,
              case .level(let level, let control) = nightRow(at: index),
              control == .decrease || control == .increase else { return nil }
        return (level, control)
    }

    /// Select held past `holdThreshold` on − or + steps at once and then
    /// repeats (`nightHoldTick`), as `TVAudioOffsetPage` does; elsewhere a
    /// hold does nothing of its own, and its tap acts as a press.
    static func nightHoldBegan(
        _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        state.selectHoldCancelledByTick = false
        guard let (level, control) = nightHeldStep(state) else { return [] }
        state.selectHold = .init(lastRepeatAt: now)
        return nightPress(control, of: level, context)
    }

    /// Repeats a held step every `selectRepeatInterval`, keeping the panel
    /// open while held. Focus leaving − or + (the panel closing) ends it.
    static func nightHoldTick(
        _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        if let until = state.swallowsSelectUntil, now > until { state.swallowsSelectUntil = nil }
        guard var hold = state.selectHold else { return [] }
        guard context.playback.acceptsInput, let (level, control) = nightHeldStep(state) else {
            state.selectHold = nil
            // The release, whenever it comes, must not act on the transport.
            state.selectHoldCancelledByTick = true
            return []
        }
        state.panel?.lastInputAt = now
        // A hair under the interval: the 10 Hz tick's sums drift.
        guard now - hold.lastRepeatAt >= TVPlayerTiming.selectRepeatInterval - 0.001 else { return [] }
        hold.lastRepeatAt = now
        state.selectHold = hold
        return nightPress(control, of: level, context)
    }
}
