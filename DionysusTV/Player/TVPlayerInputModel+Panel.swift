import Foundation

extension TVPlayerInputModel {
    /// The swipe-down panel. `nil` when it isn't open, or for Play/Pause,
    /// which the transport handles with the panel up.
    static func reducePanel(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext
    ) -> [TVPlayerCommand]? {
        guard var panel = state.panel else { return nil }
        let count = contentCount(panel.tab, context)
        switch (intent, panel.focus) {
        case (.menu, _):
            state.panel = nil
            return []
        case (.playPause, _):
            return nil
        case (.up, .tabs):
            state.panel = nil
            state.transportFocus = .scrubber
            return []
        case (.down, .tabs), (.select, .tabs):
            if count > 0 { panel.focus = .content(defaultIndex(panel.tab, context)) }
        case (.arrow(let direction), .tabs):
            panel.tab = neighbour(of: panel.tab, direction, in: availableTabs(context))
        case (.up, .content(let index)):
            panel.focus = panel.tab.isList && index > 0 ? .content(index - 1) : .tabs
        case (.down, .content(let index)):
            if panel.tab.isList, index + 1 < count, isFocusable(panel.tab, index + 1, context) {
                panel.focus = .content(index + 1)
            }
        case (.arrow(let direction), .content(let index)):
            if panel.tab == .audio, let commands = audioArrow(direction, at: index, context) {
                state.panel = panel
                return commands
            }
            if panel.tab == .chapters, count > 0 {
                panel.focus = .content(min(max(index + (direction == .left ? -1 : 1), 0), count - 1))
            }
        case (.select, .content(let index)):
            let (commands, closes) = activateRow(panel.tab, index, context)
            state.panel = closes ? nil : panel
            return commands
        case (.holdBegan, _), (.swipeBegan, _), (.swipeMoved, _), (.swipeEnded, _), (.swipeStep, _):
            // A hold's release arrives as one press; a swipe in the panel
            // arrives as an arrow (`reduce`), so nothing scrubs behind it.
            break
        }
        state.panel = panel
        return []
    }

    static func openPanel(
        _ tab: TVPanelTab, focus: TVPlayerInputState.Panel.Focus, _ state: inout TVPlayerInputState, now: TimeInterval
    ) {
        state.chrome = .transport
        state.transportFocus = .scrubber
        state.panel = .init(tab: tab, focus: focus, lastInputAt: now)
    }

    /// Chapters only when the title has them.
    static func availableTabs(_ context: TVPlayerContext) -> [TVPanelTab] {
        TVPanelTab.allCases.filter { $0 != .chapters || !context.chapterStarts.isEmpty }
    }

    static func neighbour(of tab: TVPanelTab, _ direction: TVDirection, in tabs: [TVPanelTab]) -> TVPanelTab {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.first ?? tab }
        let next = index + (direction == .left ? -1 : 1)
        return tabs.indices.contains(next) ? tabs[next] : tab
    }

    static func contentCount(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 1
        case .chapters: context.chapterStarts.count
        case .audio: context.audioTrackIDs.count + (context.audioOffset == nil ? 0 : 3)
        case .subtitles: context.subtitleTrackIDs.count + 1
        }
    }

    /// The Audio tab's row at `index`: the tracks, then (while the offset can
    /// apply) the offset, scope and Reset rows.
    static func audioRow(at index: Int, _ context: TVPlayerContext) -> TVAudioPanelRow? {
        let tracks = context.audioTrackIDs.count
        if index >= 0, index < tracks { return .track(index) }
        guard context.audioOffset != nil else { return nil }
        switch index - tracks {
        case 0: return .offset
        case 1: return .scope
        case 2: return .reset
        default: return nil
        }
    }

    /// Reset takes focus only while the title has its own offset.
    static func isFocusable(_ tab: TVPanelTab, _ index: Int, _ context: TVPlayerContext) -> Bool {
        guard tab == .audio, audioRow(at: index, context) == .reset else { return true }
        return context.audioOffset?.hasTitleOffset == true
    }

    /// Left/Right on the offset row step; on the scope row they choose a
    /// side. `nil` for a track row, which ignores arrows.
    static func audioArrow(_ direction: TVDirection, at index: Int, _ context: TVPlayerContext) -> [TVPlayerCommand]? {
        guard let offset = context.audioOffset else { return nil }
        switch audioRow(at: index, context) {
        case .offset:
            let up = direction == .right
            return (up ? offset.canIncrease : offset.canDecrease) ? [.stepAudioOffset(up ? 1 : -1)] : []
        case .scope:
            let target: AudioOffsetScope = direction == .right ? .allTitles : .thisTitle
            return target == offset.scope ? [] : [.setAudioOffsetScope(target)]
        default:
            return nil
        }
    }

    /// Where Down lands: Restart, the current chapter, the chosen track (Off
    /// is Subtitles' row 0).
    static func defaultIndex(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 0
        case .chapters: context.chapterStarts.lastIndex { $0 <= context.currentTime } ?? 0
        case .audio: context.selectedAudioIndex ?? 0
        case .subtitles: context.selectedSubtitleIndex.map { $0 + 1 } ?? 0
        }
    }

    /// A row's action, and whether it closes the panel: Restart and a
    /// chapter play from there and close; a track switch stays, so the
    /// change can be seen or heard.
    static func activateRow(
        _ tab: TVPanelTab, _ index: Int, _ context: TVPlayerContext
    ) -> (commands: [TVPlayerCommand], closesPanel: Bool) {
        switch tab {
        case .info:
            return ([.seek(0), .play], true)
        case .chapters:
            guard context.chapterStarts.indices.contains(index) else { return ([], false) }
            return ([.seek(context.chapterStarts[index]), .play], true)
        case .audio:
            switch audioRow(at: index, context) {
            case .track(let track):
                return ([.selectAudio(id: context.audioTrackIDs[track])], false)
            case .scope:
                let scope: AudioOffsetScope = context.audioOffset?.scope == .thisTitle ? .allTitles : .thisTitle
                return ([.setAudioOffsetScope(scope)], false)
            case .reset:
                return context.audioOffset?.hasTitleOffset == true ? ([.resetAudioOffset], false) : ([], false)
            case .offset, nil:
                return ([], false)
            }
        case .subtitles:
            if index == 0 { return ([.selectSubtitle(id: nil)], false) }
            guard context.subtitleTrackIDs.indices.contains(index - 1) else { return ([], false) }
            return ([.selectSubtitle(id: context.subtitleTrackIDs[index - 1])], false)
        }
    }
}
